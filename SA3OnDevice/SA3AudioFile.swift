import AVFoundation
import SwiftUI

/// Reading a take back off disk for continue / transform.
///
/// libsa3 wants PLANAR float samples and rejects anything that is not stereo — SAME's
/// `out_channels / patch_size` is 2 for every variant. AVAudioFile's processing format is already
/// deinterleaved float32, so the only work is duplicating a mono file into both channels.
enum SA3AudioFile {

    /// Seconds, or 0 when the file cannot be read. Continue needs this to place its inpaint window
    /// at the end of the source, so a silent 0 there is safer than a crash.
    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Writes a new wav holding `window` of `url` at `gainDB`, or nil if nothing can be read.
    ///
    /// What "done" in the take editor actually does. Rendering rather than carrying the settings
    /// forward keeps the rest of the app honest: continue and transform read a take off disk and
    /// hand it to libsa3, and a take that was quietly 6 dB louder than its file would arrive at
    /// the model at the wrong level.
    static func render(_ url: URL, window: ClosedRange<Double>?, gainDB: Double) -> URL? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = Int(file.length)
        guard total > 0, format.sampleRate > 0,
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(total)),
              (try? file.read(into: input)) != nil,
              let source = input.floatChannelData else { return nil }

        let read = Int(input.frameLength)
        let rate = format.sampleRate
        let from = min(max(Int((window?.lowerBound ?? 0) * rate), 0), read)
        let to = min(max(Int((window?.upperBound ?? Double(read) / rate) * rate), from), read)
        let count = to - from
        guard count > 0 else { return nil }

        let gain = Float(pow(10.0, gainDB / 20))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("edit-\(Int(Date().timeIntervalSince1970)).wav")
        guard let writer = try? AVAudioFile(forWriting: out, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.floatChannelData else { return nil }

        for channel in 0..<Int(format.channelCount) {
            let src = source[channel] + from
            let dst = destination[channel]
            for i in 0..<count {
                // Clamped here rather than left to the 16-bit conversion: a boost past full scale
                // has to fold to the rail somewhere, and doing it in float keeps it predictable.
                dst[i] = max(-1, min(1, src[i] * gain))
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard (try? writer.write(from: buffer)) != nil else { return nil }
        return out
    }

    /// Planar stereo samples laid out as `samples[channel * frameCount + frame]`.
    ///
    /// The sample rate is passed through rather than resampled here: libsa3 resamples to 44.1 kHz
    /// itself, and doing it twice would cost quality for nothing.
    static func planarStereo(_ url: URL) -> SA3Engine.InputAudio? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let n = Int(file.length)
        guard n > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }

        let read = Int(buffer.frameLength)
        guard read > 0 else { return nil }
        var planar = [Float](repeating: 0, count: read * 2)
        let left = channels[0]
        let right = format.channelCount > 1 ? channels[1] : channels[0]
        planar.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            base.update(from: left, count: read)
            (base + read).update(from: right, count: read)
        }

        // The operation is the request's business now, not the audio's.
        return SA3Engine.InputAudio(samples: planar, frameCount: read,
                                    channels: 2, sampleRate: Int(format.sampleRate))
    }
}

/// Wraps UIActivityViewController so a take can leave the app. Sharing is the only way audio gets
/// off the phone short of the Files app, and a jam is worth keeping.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
