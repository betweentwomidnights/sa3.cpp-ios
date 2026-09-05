import AVFoundation
import SwiftUI

/// What a pad does when the finger lifts.
///
/// The whole difference between a tap and a hold. `ringOut` is the MPC's one-shot: finger-up is
/// ignored and the sample plays to its end, which is right for a snare and is why a tap and a hold
/// sounded identical before this existed. `gate` fades the hit out over the given seconds, which is
/// what makes a long 808 stop when you let go of it.
enum PadRelease: Codable, Equatable {
    case ringOut
    case gate(Double)

    /// A short gate rather than ring-out, so a new pad answers the finger from the first hit.
    static let standard = PadRelease.gate(0.15)

    /// The longest gate the knob reaches. Past this the only sensible reading is "don't gate".
    private static let longest = 1.49

    /// Knob travel, 0...1, with the top stop meaning ring out. Squared, because the difference
    /// between a 20 ms choke and a 200 ms tail is most of what this control is for and a linear
    /// scale spends its travel on the second half of a second nobody adjusts.
    var position: Double {
        switch self {
        case .ringOut: return 1
        case .gate(let seconds):
            return min(0.975, (max(0, seconds - 0.01) / Self.longest).squareRoot())
        }
    }

    init(position: Double) {
        self = position >= 1 ? .ringOut : .gate(0.01 + position * position * Self.longest)
    }

    var label: String {
        switch self {
        case .ringOut: return "ring out"
        case .gate(let seconds):
            return seconds < 0.1 ? String(format: "%.0f ms", seconds * 1000)
                                 : String(format: "%.2f s", seconds)
        }
    }
}

/// One saved sample. Everything a pad needs to point at it, and enough provenance to tell two
/// hits from the same session apart.
struct Sample: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Filename only, never an absolute path — same rule as the adapter registry. The app's
    /// data-container UUID changes across reinstalls, so a stored absolute path goes stale and the
    /// sample looks deleted.
    var file: String
    var created: Date
    var seconds: Double
    /// What the take was generated from, where it was generated rather than recorded. Blank for a
    /// beatbox, which is exactly the distinction worth being able to see in a list.
    var prompt: String = ""
    var seed: UInt64?
    /// The source the take carried when it was saved, as `TakeSession.Source.rawValue`.
    var source: String = "create"
    var url: URL { SampleLibrary.dir.appendingPathComponent(file) }
}

/// One pad: which sample, and how this pad plays it.
///
/// The settings live here rather than on the sample, which is a correction. Putting them on the
/// sample meant a hit dialled in once followed it everywhere — pleasant until you drop the same
/// twelve-second loop on two pads to get the fill off one and the snare off the other, and find
/// the two pads are the same instrument wearing different labels. The sample is audio; the pad is
/// the instrument.
struct Pad: Codable, Equatable {
    var sampleID: String?
    /// The slice of the file this pad plays. Two optionals rather than a stored `ClosedRange` so
    /// the JSON stays two plain numbers and an absent pair decodes as "all of it".
    var windowStart: Double?
    var windowEnd: Double?
    var release: PadRelease?
    /// Decibels, so the useful range is symmetric around unity and the knob reads like a fader.
    var gainDB: Double?

    var window: ClosedRange<Double>? {
        guard let start = windowStart, let end = windowEnd, end > start else { return nil }
        return start...end
    }
    var releaseSetting: PadRelease { release ?? .standard }
    var decibels: Double { gainDB ?? 0 }
    var gain: Float { Float(pow(10.0, decibels / 20)) }

    /// The window as an actual range against a sample of this length. What the handles show.
    func windowOrWhole(of seconds: Double) -> ClosedRange<Double> {
        window ?? 0...max(seconds, 0.01)
    }

    /// How long this pad actually sounds for — the whole file until a window says otherwise.
    func playingSeconds(of seconds: Double) -> Double {
        window.map { $0.upperBound - $0.lowerBound } ?? seconds
    }
}

/// The saved-sample library, and which sample sits on which pad.
///
/// Both live here because they share one invariant: a pad is a pointer into the library, and
/// deleting a sample has to clear every pad holding it. Splitting them would leave that rule with
/// nowhere to live.
///
/// Storage mirrors the adapter registry — a directory of files plus one `library.json` beside
/// them, filtered against the filesystem on load — so a sample deleted through the Files app
/// disappears from the app rather than becoming a pad that plays nothing.
@MainActor
final class SampleLibrary: ObservableObject {

    static let padCount = 8

    @Published private(set) var samples: [Sample] = []
    /// Fixed length; the array index is the pad number.
    @Published private(set) var pads: [Pad] = Array(repeating: Pad(), count: padCount)

    /// nonisolated for the same reason `SA3Engine.adaptersDir` is: it is a pure path lookup, and
    /// `Sample.url` — a plain struct — resolves against it.
    nonisolated static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("samples")
    }
    private static var indexURL: URL { dir.appendingPathComponent("library.json") }
    private static let legacyPadsKey = "padSampleIDs"

    /// Samples and pads in one file, so a reassignment and the settings that go with it are one
    /// atomic write rather than two that can disagree.
    private struct Archive: Codable {
        var samples: [Sample]
        var pads: [Pad]
    }

    init() {
        load()
    }

    // MARK: - reading

    func sample(id: String?) -> Sample? {
        guard let id else { return nil }
        return samples.first { $0.id == id }
    }

    func pad(_ index: Int) -> Pad {
        pads.indices.contains(index) ? pads[index] : Pad()
    }

    func sample(onPad index: Int) -> Sample? {
        sample(id: pad(index).sampleID)
    }

    /// What the pad face should say it is: the window when there is one, the file otherwise.
    func playingSeconds(onPad index: Int) -> Double {
        pad(index).playingSeconds(of: sample(onPad: index)?.seconds ?? 0)
    }

    /// The pad a new sample should land on: the first empty one, or nil when the bank is full.
    var firstEmptyPad: Int? { pads.firstIndex(where: { $0.sampleID == nil }) }

    var filledCount: Int { pads.filter { $0.sampleID != nil }.count }

    // MARK: - writing

    /// Copies a take into the library. Copies rather than moves: the take is still the current one
    /// in the jam tab, and the undo stack behind it holds URLs.
    @discardableResult
    func save(_ url: URL, name: String, source: TakeSession.Source, prompt: String,
              seed: UInt64?) -> Sample? {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let file = "\(id).wav"
        let dst = Self.dir.appendingPathComponent(file)
        do { try fm.copyItem(at: url, to: dst) } catch { return nil }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = Sample(id: id, name: trimmed.isEmpty ? "untitled" : trimmed, file: file,
                            created: Date(), seconds: SA3AudioFile.duration(dst),
                            prompt: prompt, seed: seed, source: source.rawValue)
        samples.insert(sample, at: 0)
        write()
        return sample
    }

    func rename(_ sample: Sample, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = samples.firstIndex(where: { $0.id == sample.id }) else {
            return
        }
        samples[i].name = trimmed
        write()
    }

    func delete(_ sample: Sample) {
        try? FileManager.default.removeItem(at: sample.url)
        samples.removeAll { $0.id == sample.id }
        // A pad pointing at a deleted sample would render as filled and play nothing. Its settings
        // go with it — they described a slice of audio that no longer exists.
        for i in pads.indices where pads[i].sampleID == sample.id { pads[i] = Pad() }
        write()
    }

    // MARK: - pads

    /// Assigning resets the pad. The settings belong to the pad, and inheriting the last sample's
    /// window would point a trim at audio it was never measured against.
    func assign(_ sample: Sample?, toPad index: Int) {
        guard pads.indices.contains(index) else { return }
        pads[index] = Pad(sampleID: sample?.id)
        write()
    }

    /// nil clears the trim back to the whole sample.
    func setWindow(_ window: ClosedRange<Double>?, onPad index: Int) {
        guard pads.indices.contains(index) else { return }
        let whole = sample(onPad: index)?.seconds ?? 0
        // A window that spans the file is stored as no window at all, so "trimmed" and "not
        // trimmed" have one representation rather than two that behave the same.
        if let window, window.lowerBound > 0.001 || window.upperBound < whole - 0.001 {
            pads[index].windowStart = window.lowerBound
            pads[index].windowEnd = window.upperBound
        } else {
            pads[index].windowStart = nil
            pads[index].windowEnd = nil
        }
        write()
    }

    func setRelease(_ release: PadRelease, onPad index: Int) {
        guard pads.indices.contains(index) else { return }
        pads[index].release = release
        write()
    }

    func setGain(_ decibels: Double, onPad index: Int) {
        guard pads.indices.contains(index) else { return }
        pads[index].gainDB = abs(decibels) < 0.05 ? nil : decibels
        write()
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            let fm = FileManager.default
            samples = archive.samples.filter { fm.fileExists(atPath: $0.url.path) }
            pads = Self.normalise(archive.pads, against: samples)
            if samples.count != archive.samples.count { write() }
            return
        }
        migrate(data)
    }

    /// The shape the library had when a window and a release belonged to the sample and the pad
    /// assignments lived in UserDefaults. Read once, so an existing bank survives the change.
    private struct LegacyEntry: Codable {
        var id: String
        var windowStart: Double?
        var windowEnd: Double?
        var release: PadRelease?
    }

    private func migrate(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return }
        let fm = FileManager.default
        samples = decoded.filter { fm.fileExists(atPath: $0.url.path) }

        let legacy = (try? JSONDecoder().decode([LegacyEntry].self, from: data)) ?? []
        let settings = Dictionary(legacy.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let assigned = UserDefaults.standard.array(forKey: Self.legacyPadsKey) as? [String] ?? []

        var restored = Array(repeating: Pad(), count: Self.padCount)
        for (i, id) in assigned.prefix(Self.padCount).enumerated() where !id.isEmpty {
            guard samples.contains(where: { $0.id == id }) else { continue }
            let old = settings[id]
            restored[i] = Pad(sampleID: id, windowStart: old?.windowStart,
                              windowEnd: old?.windowEnd, release: old?.release)
        }
        pads = restored
        UserDefaults.standard.removeObject(forKey: Self.legacyPadsKey)
        write()
    }

    /// Guards against a hand-edited or truncated file: the rest of the app indexes `pads` by pad
    /// number and assumes the array is exactly `padCount` long.
    private static func normalise(_ pads: [Pad], against samples: [Sample]) -> [Pad] {
        var out = Array(repeating: Pad(), count: padCount)
        for (i, pad) in pads.prefix(padCount).enumerated() {
            guard let id = pad.sampleID else { continue }
            out[i] = samples.contains(where: { $0.id == id }) ? pad : Pad()
        }
        return out
    }

    private func write() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Archive(samples: samples, pads: pads)) else {
            return
        }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}
