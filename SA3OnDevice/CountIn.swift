import AVFoundation
import SwiftUI

/// The metronome that runs before a take starts.
///
/// Its own type because two things want it now: the microphone, which has had one since it was
/// ported over from gary, and the pads, where it matters more — without it a pad take opens with
/// however long it took to get a thumb onto the first pad.
///
/// It plays through `AVAudioPlayer`, which sits outside `PadEngine`'s graph. That is not an
/// accident: the pad recording taps the graph's main mixer, so a click played this way is audible
/// while it counts and absent from the file, which is what a count-in is supposed to be.
@MainActor
final class CountIn: ObservableObject {

    /// The beat currently sounding, nil when nothing is counting.
    @Published private(set) var beat: Int?

    var isRunning: Bool { beat != nil }

    private var timer: Timer?
    private var click: AVAudioPlayer?
    private var accent: AVAudioPlayer?

    /// Counts, then calls `then`. Both consumers want the beat for their own UI, so it is
    /// published here and also handed to `onBeat` — the recorder mirrors it into its own state,
    /// the drawer reads it straight off this object.
    func run(bpm: Int, beats: Int, onBeat: ((Int?) -> Void)? = nil,
             then completion: @escaping () -> Void) {
        cancel()
        let interval = 60.0 / Double(max(30, min(300, bpm)))
        let total = max(1, beats)
        var current = 0

        func advance() {
            current += 1
            if current > total {
                cancel()
                onBeat?(nil)
                completion()
            } else {
                beat = current
                onBeat?(current)
                play(accented: current == 1)
            }
        }

        // Beat one lands on the tap. Scheduling it a beat out — as a plain repeating timer does —
        // reads as a dead button.
        advance()
        guard beat != nil else { return }        // a one-beat count is already finished
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { advance() }
        }
        // `.common` so the count keeps time while a scroll view is tracking a finger.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        beat = nil
    }

    private func play(accented: Bool) {
        if click == nil {
            click = try? AVAudioPlayer(data: Self.clickWAV(frequency: 880))
            accent = try? AVAudioPlayer(data: Self.clickWAV(frequency: 1320))
            click?.prepareToPlay()
            accent?.prepareToPlay()
        }
        let player = accented ? accent : click
        player?.currentTime = 0
        player?.play()
    }

    /// A click synthesised rather than bundled: it is forty milliseconds of decaying sine, and a
    /// wav in the bundle would be one more thing to keep in the project file.
    private static func clickWAV(frequency: Double) -> Data {
        let rate = 44_100.0, seconds = 0.04
        let n = Int(rate * seconds)
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            pcm[i] = Int16(sin(2 * .pi * frequency * t) * exp(-t * 90) * 22_000)
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(n * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return data
    }
}
