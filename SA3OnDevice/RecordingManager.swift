import AVFoundation
import SwiftUI

/// The mic. One recording at a time, straight to a wav the jam tab can adopt as a take.
///
/// Lifted from gary-for-beatbox's RecordingViewModel, keeping the two decisions that mattered
/// there. Linear PCM rather than AAC, because an AAC file carries encoder priming and its duration
/// stops being an exact sample count — continue places its inpaint window at the end of the source,
/// so a duration that is off by a few frames puts the seam in the wrong place. And noise
/// cancellation stays a choice: `.voiceChat` runs Apple's voice processing, which gates and
/// compresses exactly the transients a beatbox is made of, so raw is the default.
@MainActor
final class RecordingManager: NSObject, ObservableObject {

    enum Permission { case unknown, granted, denied }

    @Published private(set) var isRecording = false
    /// Which beat of the count-in is sounding; nil when no count-in is running.
    @Published private(set) var countInBeat: Int?
    @Published private(set) var elapsed: Double = 0
    /// 0...1, from the recorder's average power. For the meter only — nothing reads it back.
    @Published private(set) var level: Double = 0
    @Published private(set) var permission: Permission = .unknown

    /// True from the tap until the file lands, count-in included. The jam tab swaps the take card
    /// for the recording card on this rather than on `isRecording`, so the count-in has somewhere
    /// to be drawn.
    var isActive: Bool { isRecording || countInBeat != nil }

    // Filled in from SA3Settings before each `start`.
    var countInEnabled = false
    var bpm = 120
    var beats = 4
    var cancelNoise = false
    var maxSeconds: Double = 30

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    /// Shared with the pads. The recorder still owns the ordering — permission, then the count,
    /// then the capture — because asking for the mic mid-count would put the system prompt on
    /// screen halfway through the bar.
    private let countIn = CountIn()
    private var onFinish: ((URL?) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: - start / stop

    /// Asks for the mic if it has not been asked yet, then records. `completion` runs exactly once:
    /// with the file when a recording lands, with nil for a refusal, a failure, or a cancel — the
    /// caller distinguishes a denial by reading `permission`.
    func start(_ completion: @escaping (URL?) -> Void) {
        guard !isActive else { return }
        onFinish = completion
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.deliver(nil); return }
            self.begin()
        }
    }

    /// Ends the take early. During a count-in this is a cancel — nothing has been captured yet — so
    /// it delivers nil rather than a zero-length file.
    func stop() {
        if countInBeat != nil {
            cancelCount()
            deactivate()
            deliver(nil)
            return
        }
        // The delegate is what delivers: `stop()` finishes writing the file asynchronously, and
        // handing back the URL before that is what produces a take with no audio in it.
        recorder?.stop()
    }

    /// Also the mic overdub's way in. That path records through `PadEngine` rather than through
    /// this class, but the permission and the denial alert behind it should have one owner — and
    /// `permission` is already what the jam tab reads to decide whether a nil result was a refusal.
    func requestPermission(_ then: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
            then(true)
        case .denied:
            permission = .denied
            then(false)
        default:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    self.permission = granted ? .granted : .denied
                    then(granted)
                }
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` so a count-in does not duck whatever else the phone is playing, and
        // `.defaultToSpeaker` so it comes out of the loudspeaker rather than the earpiece.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)

        guard prepare() else { deactivate(); deliver(nil); return }

        if countInEnabled {
            countIn.run(bpm: bpm, beats: beats,
                        onBeat: { [weak self] in self?.countInBeat = $0 }) { [weak self] in
                self?.capture()
            }
        } else {
            capture()
        }
    }

    private func prepare() -> Bool {
        // A unique name per take. gary recorded over one `recording.wav` and copied it into a
        // library; there is no library here, and the undo stack holds URLs — reusing one path
        // would leave every earlier take pointing at the newest audio.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.delegate = self
        r.isMeteringEnabled = true
        r.prepareToRecord()
        recorder = r
        return true
    }

    private func capture() {
        // `.voiceChat` engages Apple's voice processing; `.videoRecording` is the closest thing to
        // an unprocessed capture the shared session offers.
        try? AVAudioSession.sharedInstance().setMode(cancelNoise ? .voiceChat : .videoRecording)
        // `record(forDuration:)` rather than a watchdog timer: the recorder stops itself and files
        // through the same delegate as a manual stop, so there is one finish path.
        guard recorder?.record(forDuration: maxSeconds) == true else {
            deactivate()
            deliver(nil)
            return
        }
        elapsed = 0
        level = 0
        isRecording = true
        startMetering()
    }

    // MARK: - meter

    private func startMetering() {
        stopMetering()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -50 dB is the floor: below that is room tone, and mapping from -160 would leave the bar
        // pinned near zero for everything short of a shout.
        let db = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (db + 50) / 50))
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    // MARK: - finish

    @objc private nonisolated func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        // A call arriving mid-take stops the recorder without telling the delegate, which would
        // otherwise leave the tab stuck on the recording card. Keep whatever was captured.
        Task { @MainActor in
            guard self.isActive else { return }
            self.stop()
        }
    }

    private func cancelCount() {
        countIn.cancel()
        countInBeat = nil
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    private func deliver(_ url: URL?) {
        stopMetering()
        cancelCount()
        isRecording = false
        level = 0
        let finish = onFinish
        onFinish = nil
        recorder = nil
        finish?(url)
    }
}

extension RecordingManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder,
                                                     successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in
            self.elapsed = 0
            self.deactivate()
            self.deliver(flag ? url : nil)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder,
                                                      error: Error?) {
        Task { @MainActor in
            self.deactivate()
            self.deliver(nil)
        }
    }
}
