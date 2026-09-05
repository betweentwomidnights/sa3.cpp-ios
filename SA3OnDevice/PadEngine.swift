import AVFoundation
import SwiftUI

/// The pads' audio graph.
///
/// Deliberately not `AVAudioPlayer`, which is what the take player and the recorder use.
/// `AVAudioPlayer` decodes on demand and takes tens of milliseconds to start, and it cannot
/// retrigger while it is already sounding — fine for auditioning a take, useless under a finger.
/// Here every sample is resident as a PCM buffer and every pad owns a player node that is already
/// running, so a press is one `scheduleBuffer` and the next render quantum.
///
/// The graph is flat: eight `AVAudioPlayerNode`s straight into the main mixer. A per-pad
/// `AVAudioMixerNode` would be the obvious place to put the release, but `AVAudioMixing.volume` on
/// the player node does the same job at the mixer's input bus, so the extra node would be eight
/// more render callbacks for nothing.
@MainActor
final class PadEngine: ObservableObject {

    @Published private(set) var running = false
    /// Which pads are under a finger. Drives the pad highlight, nothing else — a let-ring pad goes
    /// on sounding after this clears, which is the point of letting it ring.
    @Published private(set) var held: Set<Int> = []
    @Published private(set) var recording = false
    @Published private(set) var recordedSeconds: Double = 0

    /// Everything is converted to this on load, so every connection carries one format and a mono
    /// recording drops onto a pad beside a stereo generation without a graph rebuild.
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    private let engine = AVAudioEngine()
    private var voices: [Voice] = []
    /// The current take, when a recording is overdubbing onto it. It lives in this graph rather
    /// than on `AudioPlayerManager` for exactly one reason: the tap is on the main mixer, so
    /// anything that plays through here is in the file and anything that does not, is not.
    private let takeNode = AVAudioPlayerNode()
    private var capture: Capture?
    private var clock: Timer?

    @MainActor
    private final class Voice {
        let player = AVAudioPlayerNode()
        /// The whole decoded file, kept so that moving a trim handle re-slices from memory rather
        /// than going back to disk.
        var full: AVAudioPCMBuffer?
        /// The slice actually scheduled — `full` itself when the sample is untrimmed.
        var buffer: AVAudioPCMBuffer?
        var sampleID: String?
        var window: ClosedRange<Double>?
        /// What finger-up does. Comes off the sample, so it survives being moved between pads.
        var release: PadRelease = .standard
        /// Linear, already converted from the pad's decibels. Every place that touches
        /// `player.volume` goes through this so a release fade lands back on the pad's level
        /// rather than on unity.
        var gain: Float = 1
        private var ramp: Timer?

        /// True while a release fade is in flight, so a settings refresh does not stamp the pad's
        /// level back on top of a ramp that is halfway down.
        var isRamping: Bool { ramp != nil }

        func cancelRamp() {
            ramp?.invalidate()
            ramp = nil
        }

        /// A stepped ramp rather than a sample-accurate envelope. `AVAudioMixing.volume` is
        /// smoothed by the mixer across a render quantum, so 60 Hz steps land under the audible
        /// threshold for a zipper; a pre-rendered fade buffer would be exact, and is what to reach
        /// for if a very short release ever clicks.
        func fade(over seconds: Double, then done: @escaping () -> Void) {
            cancelRamp()
            let from = player.volume
            let steps = max(1, Int(seconds * 60))
            var step = 0
            let timer = Timer(timeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    step += 1
                    self.player.volume = from * (1 - Float(step) / Float(steps))
                    guard step >= steps else { return }
                    t.invalidate()
                    self.ramp = nil
                    done()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ramp = timer
        }
    }

    init() {
        voices = (0..<SampleLibrary.padCount).map { _ in Voice() }
        for voice in voices {
            engine.attach(voice.player)
            engine.connect(voice.player, to: engine.mainMixerNode, format: Self.format)
        }
        engine.attach(takeNode)
        engine.connect(takeNode, to: engine.mainMixerNode, format: Self.format)
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    // MARK: - lifecycle

    /// Called when the drawer opens. The engine is not kept running behind a closed drawer: it
    /// holds the audio session active, and an active session is what stops the recorder and the
    /// take player from configuring their own.
    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        // The number that actually decides whether a pad feels tight. It is a request, not a
        // guarantee — the OS grants what the route allows — but asking for 5 ms is the difference
        // between a pad and a button that eventually makes a sound.
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)

        engine.prepare()
        do { try engine.start() } catch { return }
        // Nodes stay running with nothing scheduled, rendering silence. Starting a node costs more
        // than scheduling a buffer into one that is already going, and that cost would land on the
        // first hit of every pad.
        for voice in voices { voice.player.play() }
        takeNode.play()
        running = true
    }

    func stop() {
        guard running else { return }
        // A capture outlives its engine as a half-written file otherwise. Nothing is delivered:
        // the callers that stop the engine are doing so to hand the session to something else.
        if capture != nil { stopRecording { _ in } }
        held.removeAll()
        for voice in voices {
            voice.cancelRamp()
            voice.player.stop()
            voice.player.volume = voice.gain
        }
        stopAudition()
        takeNode.stop()
        engine.stop()
        running = false
    }

    /// A route change (headphones in or out) stops the engine underneath us and leaves every node
    /// detached from its old format. Rebuilding is `start()`'s job; this just gets us back.
    @objc private nonisolated func configurationChanged(_ note: Notification) {
        Task { @MainActor in
            guard self.running else { return }
            self.running = false
            self.start()
        }
    }

    // MARK: - loading

    /// Points a pad at a sample, or clears it with nil. Reading the file happens here rather than
    /// on the first press, so the first hit is as fast as the hundredth.
    ///
    /// Release costs nothing to reapply, so it is written every time. The buffer is the expensive
    /// part and only rebuilt when the sample or its window actually moved.
    func load(_ sample: Sample?, settings pad: Pad, onPad index: Int) {
        guard voices.indices.contains(index) else { return }
        let voice = voices[index]
        // Release and gain are a property write each, so they are reapplied unconditionally; the
        // buffer is the expensive part and only rebuilt when the audio actually changed.
        voice.release = pad.releaseSetting
        voice.gain = pad.gain
        if !voice.isRamping { voice.player.volume = pad.gain }

        let window = sample == nil ? nil : pad.window
        let sameSample = voice.sampleID == sample?.id
        guard !sameSample || voice.window != window || (sample != nil && voice.buffer == nil) else {
            return
        }

        voice.cancelRamp()
        voice.player.stop()
        // Decode only when the sample changed; a trim is a re-slice of what is already in memory.
        if !sameSample || voice.full == nil {
            voice.full = sample.flatMap { Self.buffer(from: $0.url) }
        }
        voice.buffer = voice.full.flatMap { Self.slice($0, to: window) }
        voice.sampleID = sample?.id
        voice.window = window
        voice.player.volume = pad.gain
        if running { voice.player.play() }
    }

    /// The windowed copy a pad plays. Returns the buffer unchanged when the window covers it, so
    /// an untrimmed sample costs no second allocation.
    private static func slice(_ buffer: AVAudioPCMBuffer,
                              to window: ClosedRange<Double>?) -> AVAudioPCMBuffer? {
        guard let window else { return buffer }
        let rate = buffer.format.sampleRate
        let total = Int(buffer.frameLength)
        let from = min(max(Int(window.lowerBound * rate), 0), total)
        let to = min(max(Int(window.upperBound * rate), from), total)
        let count = to - from
        guard count > 0 else { return buffer }
        if from == 0 && to == total { return buffer }

        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: AVAudioFrameCount(count)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            dst[channel].update(from: src[channel] + from, count: count)
        }
        out.frameLength = AVAudioFrameCount(count)
        return out
    }

    func isLoaded(_ index: Int) -> Bool {
        voices.indices.contains(index) && voices[index].buffer != nil
    }

    // MARK: - playing

    func press(_ index: Int) {
        guard running, voices.indices.contains(index) else { return }
        let voice = voices[index]
        guard let buffer = voice.buffer else { return }
        voice.cancelRamp()
        voice.player.volume = voice.gain
        // `.interrupts` replaces whatever is sounding at the next render cycle without stopping
        // the node, which is what makes a fast retrigger possible at all — `stop()` then `play()`
        // would drop a buffer's worth of audio on every hit.
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        held.insert(index)
    }

    func release(_ index: Int) {
        held.remove(index)
        guard running, voices.indices.contains(index) else { return }
        let voice = voices[index]
        // A one-shot ignores the finger coming up; that is the whole distinction.
        guard case .gate(let seconds) = voice.release, seconds > 0 else { return }
        voice.fade(over: seconds) { [weak voice] in
            guard let voice else { return }
            voice.player.stop()
            voice.player.volume = voice.gain
            voice.player.play()
        }
    }


    // MARK: - capture

    /// Writes the mixer tap to disk.
    ///
    /// The tap block runs on the render thread, so it does two things and neither is file I/O: it
    /// copies the buffer — the engine reuses the one it hands you the moment the callback returns —
    /// and hands the copy to a serial queue. An allocation per callback is not free either, but it
    /// is bounded and predictable, which a filesystem stall on the render thread is not.
    ///
    /// `@unchecked Sendable` is earned rather than assumed: `file` is only ever touched from the
    /// one serial queue below, and `written` is behind the lock. Nothing else is mutable.
    private final class Capture: @unchecked Sendable {
        let url: URL
        let sampleRate: Double

        private let queue = DispatchQueue(label: "sa3.pads.capture")
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var written: AVAudioFramePosition = 0

        init?(url: URL, format: AVAudioFormat) {
            // 16-bit rather than the mixer's float32, to match every other wav the app writes.
            // AVAudioFile converts on the way down; its processing format stays float.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            guard let f = try? AVAudioFile(forWriting: url, settings: settings) else { return nil }
            self.url = url
            self.sampleRate = format.sampleRate
            self.file = f
        }

        var seconds: Double {
            lock.lock(); defer { lock.unlock() }
            return sampleRate > 0 ? Double(written) / sampleRate : 0
        }

        func accept(_ buffer: AVAudioPCMBuffer) {
            let frames = buffer.frameLength
            guard frames > 0,
                  let made = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
                  let src = buffer.floatChannelData, let dst = made.floatChannelData else { return }
            made.frameLength = frames
            for channel in 0..<Int(buffer.format.channelCount) {
                dst[channel].update(from: src[channel], count: Int(frames))
            }
            // Freshly allocated here and read only on the queue below, so it is handed over rather
            // than shared — which is the thing AVAudioPCMBuffer's lack of Sendable cannot express.
            nonisolated(unsafe) let copy = made
            queue.async { [weak self] in
                guard let self, let file = self.file else { return }
                try? file.write(from: copy)
                self.lock.lock()
                self.written += AVAudioFramePosition(frames)
                self.lock.unlock()
            }
        }

        /// Drains whatever the queue is still holding, then releases the file — deallocating an
        /// AVAudioFile is what writes the final header, and there is no close() to call instead.
        /// Strongly captured on purpose. By the time this runs the tap has been removed and the
        /// engine has dropped its reference, so a weak capture would find nothing left and report
        /// a failed recording for a file that was written perfectly well. Holding on until the
        /// queue drains is the point — it is also what keeps the pending writes above alive.
        func finish(_ completion: @escaping (URL?) -> Void) {
            queue.async {
                self.file = nil
                let any = self.seconds > 0
                DispatchQueue.main.async { completion(any ? self.url : nil) }
            }
        }
    }

    /// Records what the pads are playing. Nothing to do with the microphone — this is the graph's
    /// own output, so it needs no permission and no `.playAndRecord` session.
    ///
    /// The tap sits on the main mixer rather than on the pad nodes, which is the part that matters
    /// long term: anything routed into this graph later lands in the recording without the capture
    /// code changing. Overlaying pads onto the current take is exactly that — give the take its own
    /// player node here instead of leaving it on `AudioPlayerManager`, and "add" falls out of the
    /// same tap that "replace" already uses.
    /// `over` is the whole difference between replace and add. Pass nil and the file is the pads
    /// alone; pass the current take and it is played into the same mix, so what comes back is the
    /// take with your performance on top. The capture code is identical either way — the graph is
    /// what changed, which is why this was worth building as a graph in the first place.
    ///
    /// `onTakeEnded` fires when the overdubbed take has finished playing back, so the caller can
    /// end the recording exactly where the source ended rather than leaving a tail of pads over
    /// silence.
    @discardableResult
    func startRecording(over take: URL? = nil,
                        onTakeEnded: @escaping () -> Void = {}) -> Bool {
        guard running, capture == nil else { return false }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pads-\(Int(Date().timeIntervalSince1970)).wav")
        guard let capture = Capture(url: url, format: format) else { return false }

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            capture.accept(buffer)
        }
        // Scheduled after the tap is live so the take's first sample is in the file. Both happen
        // inside a render quantum, so the head of the overdub is not measurably late.
        if let take, let buffer = Self.buffer(from: take) {
            takeNode.volume = 1
            takeNode.scheduleBuffer(buffer, at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { _ in
                Task { @MainActor in onTakeEnded() }
            }
        }
        self.capture = capture
        recordedSeconds = 0
        recording = true

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordedSeconds = self?.capture?.seconds ?? 0 }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        return true
    }

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        guard let capture else { completion(nil); return }
        engine.mainMixerNode.removeTap(onBus: 0)
        // Stopping and restarting clears anything still scheduled, so a second overdub does not
        // inherit the tail of the first.
        takeNode.stop()
        if running { takeNode.play() }
        clock?.invalidate()
        clock = nil
        self.capture = nil
        recording = false
        recordedSeconds = 0
        capture.finish(completion)
    }

// MARK: - auditioning an edit

    /// Plays a slice of a take at a given gain, through the same node an overdub uses.
    ///
    /// The take editor needs to hear a boost, and `AVAudioPlayer.volume` stops at unity — a fader
    /// that cannot go above 0 dB is not a fader. A player node's volume has no such ceiling, and
    /// this graph already has one pointed at the take.
    @Published private(set) var auditioning = false
    private var auditionSource: (url: URL, buffer: AVAudioPCMBuffer)?

    func audition(_ url: URL, window: ClosedRange<Double>?, gainDB: Double) {
        guard !recording else { return }
        if !running { start() }
        guard running else { return }

        // Cached across taps: dialling a window in means auditioning repeatedly, and decoding the
        // whole take each time would put a hitch between the tap and the sound.
        if auditionSource?.url != url {
            guard let decoded = Self.buffer(from: url) else { return }
            auditionSource = (url, decoded)
        }
        guard let slice = auditionSource.flatMap({ Self.slice($0.buffer, to: window) }) else {
            return
        }
        takeNode.volume = Float(pow(10.0, gainDB / 20))
        takeNode.scheduleBuffer(slice, at: nil, options: .interrupts,
                                completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in self.auditioning = false }
        }
        auditioning = true
    }

    func stopAudition() {
        guard auditioning else { return }
        takeNode.stop()
        takeNode.volume = 1
        if running { takeNode.play() }
        auditioning = false
    }

    // MARK: - decoding

    /// Reads a file into a buffer in the graph's format, converting when it is not already there.
    /// In practice the only conversion that runs is mono to stereo: generations come out of libsa3
    /// at 44.1 kHz stereo, and recordings are 44.1 kHz mono.
    private static func buffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let source = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
              (try? file.read(into: input)) != nil, input.frameLength > 0 else { return nil }
        if source == format { return input }

        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        // `convert` runs the block synchronously on this thread before returning, so the buffer
        // never actually crosses an isolation boundary — the annotation is what says so, since
        // AVFAudio types the block as @Sendable.
        nonisolated(unsafe) let pcm = input
        converter.convert(to: output, error: &error) { _, status in
            // The whole sample is already in memory, so it goes across in one block; anything
            // after that is the converter asking for more, and there is none.
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return pcm
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
