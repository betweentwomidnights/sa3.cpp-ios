import Foundation

/// Everything the jam tabs share, in one place.
///
/// create / continue / transform are deliberately identical apart from their source audio, which
/// only works if the model set, the adapter blend and the sampler settings live outside all three.
/// That is this object: the tabs read it, Settings writes it, and it is the only thing that knows
/// what the app is configured to run.
///
/// Persistence is UserDefaults on `didSet` rather than `@AppStorage`. A jam session is a long
/// sequence of small adjustments and losing the blend on relaunch is worse than the boilerplate.
@MainActor
final class SA3Settings: ObservableObject {

    // MARK: - model set

    @Published var variant: String = Store.string("variant", "small-music") {
        didSet { Store.set(variant, "variant") }
    }
    /// The DiT tier. Named `ditEncoding` rather than `encoding` because the text encoder and the
    /// autoencoder resolve on their own axes — see sa3_context_config_v1.
    @Published var ditEncoding: String = Store.string("ditEncoding", "q4_k_m") {
        didSet { Store.set(ditEncoding, "ditEncoding") }
    }
    @Published var textEncoding: String = Store.string("textEncoding", "q8_0") {
        didSet { Store.set(textEncoding, "textEncoding") }
    }
    @Published var aeEncoding: String = Store.string("aeEncoding", "f32") {
        didSet { Store.set(aeEncoding, "aeEncoding") }
    }
    /// Forces the CPU backend. Slow, but it isolates a Metal fault from a bug in the path itself.
    @Published var useCPU: Bool = Store.bool("useCPU", false) {
        didSet { Store.set(useCPU, "useCPU") }
    }
    /// Per-request residency. Frugal trades a reload (~0.5-1.5 s) for a much lower peak, which is
    /// what decides whether the heavier encodings survive on a 4 GB phone.
    @Published var keepModels: Bool = Store.bool("keepModels", true) {
        didSet { Store.set(keepModels, "keepModels") }
    }

    // MARK: - adapters

    /// Whether the DiT blend contributes at all. Off is the base model, whatever the sliders say.
    @Published var useLoras: Bool = Store.bool("useLoras", false) {
        didSet { Store.set(useLoras, "useLoras") }
    }
    /// DiT adapter strengths by registry id. A blend rather than a single choice: several DiT
    /// adapters merge in one request, each with its own weight.
    @Published var ditStrengths: [String: Double] = Store.strengths("ditStrengths") {
        didSet { Store.setStrengths(ditStrengths, "ditStrengths") }
    }
    /// The autoencoder adapters are a single slot each and live here rather than in the tabs: they
    /// fix the decode, which is the same job whether the audio came from create or transform.
    @Published var decoderAdapterID: String? = Store.optString("decoderAdapterID") {
        didSet { Store.set(decoderAdapterID, "decoderAdapterID") }
    }
    @Published var decoderStrength: Double = Store.double("decoderStrength", 1.0) {
        didSet { Store.set(decoderStrength, "decoderStrength") }
    }
    @Published var encoderAdapterID: String? = Store.optString("encoderAdapterID") {
        didSet { Store.set(encoderAdapterID, "encoderAdapterID") }
    }
    @Published var encoderStrength: Double = Store.double("encoderStrength", 1.0) {
        didSet { Store.set(encoderStrength, "encoderStrength") }
    }

    // MARK: - sampler, shared by all three actions

    @Published var steps: Int = Store.int("steps", 8) {
        didSet { Store.set(steps, "steps") }
    }
    /// 1.0 is CFG off — a single DiT pass per step. Anything else roughly doubles the cost.
    @Published var cfgScale: Double = Store.double("cfgScale", 1.0) {
        didSet { Store.set(cfgScale, "cfgScale") }
    }
    @Published var distShift: String = Store.string("distShift", "LogSNR") {
        didSet { Store.set(distShift, "distShift") }
    }
    @Published var negativePrompt: String = Store.string("negativePrompt", "") {
        didSet { Store.set(negativePrompt, "negativePrompt") }
    }
    @Published var useManualSeed: Bool = Store.bool("useManualSeed", false) {
        didSet { Store.set(useManualSeed, "useManualSeed") }
    }
    @Published var manualSeed: Int = Store.int("manualSeed", 42) {
        didSet { Store.set(manualSeed, "manualSeed") }
    }

    // MARK: - per-action

    @Published var createPrompt: String = Store.string("createPrompt", "funk soul-jazz, 88 bpm, G minor") {
        didSet { Store.set(createPrompt, "createPrompt") }
    }
    /// Seconds. Converted to latent frames at the shared 10.767 fps; this is the knob that moves
    /// peak memory, since SAME-S decodes the whole clip at once.
    @Published var createDuration: Double = Store.double("createDuration", 11.9) {
        didSet { Store.set(createDuration, "createDuration") }
    }
    /// Schedule headroom in seconds. 6 is libsa3's default (no ending); 0 lets the model land it.
    @Published var durationPadding: Double = Store.double("durationPadding", 6) {
        didSet { Store.set(durationPadding, "durationPadding") }
    }

    @Published var continuePrompt: String = Store.string("continuePrompt", "") {
        didSet { Store.set(continuePrompt, "continuePrompt") }
    }
    @Published var continueAddSeconds: Double = Store.double("continueAddSeconds", 11.9) {
        didSet { Store.set(continueAddSeconds, "continueAddSeconds") }
    }

    @Published var transformPrompt: String = Store.string("transformPrompt", "") {
        didSet { Store.set(transformPrompt, "transformPrompt") }
    }
    /// How much of the source survives. libsa3 defaults to 0.85, which keeps very little; the
    /// useful range for a recognisable transform is well below that.
    @Published var transformNoise: Double = Store.double("transformNoise", 0.5) {
        didSet { Store.set(transformNoise, "transformNoise") }
    }

    // MARK: - the mic

    /// Off is the raw capture. On engages `.voiceChat`, and with it Apple's voice processing —
    /// gating, AGC, noise suppression — which is tuned for speech and flattens the transients a
    /// beatbox is made of. Worth having for a noisy room, wrong for a performance.
    @Published var cancelNoise: Bool = Store.bool("cancelNoise", false) {
        didSet { Store.set(cancelNoise, "cancelNoise") }
    }
    @Published var countIn: Bool = Store.bool("countIn", false) {
        didSet { Store.set(countIn, "countIn") }
    }
    @Published var countInBPM: Int = Store.int("countInBPM", 120) {
        didSet { Store.set(countInBPM, "countInBPM") }
    }
    @Published var countInBeats: Int = Store.int("countInBeats", 4) {
        didSet { Store.set(countInBeats, "countInBeats") }
    }
    /// A hard stop, because the recorder is armed by one tap and nothing else ends it. It also
    /// bounds what continue and transform have to re-encode: the source crosses the autoencoder on
    /// every pass, and a five-minute take is what runs a 4 GB phone out of memory.
    @Published var maxRecordSeconds: Double = Store.double("maxRecordSeconds", 30) {
        didSet { Store.set(maxRecordSeconds, "maxRecordSeconds") }
    }

    // MARK: - training

    @Published var trainSteps: Double = Store.double("trainSteps", 20) {
        didSet { Store.set(trainSteps, "trainSteps") }
    }
    /// Training crop, in seconds. The backward pass holds activations for the whole crop, so this
    /// is the knob that decides whether a run fits at all.
    @Published var cropSeconds: Double = Store.double("cropSeconds", 5.9) {
        didSet { Store.set(cropSeconds, "cropSeconds") }
    }
    @Published var rank: Double = Store.double("rank", 16) {
        didSet { Store.set(rank, "rank") }
    }
    @Published var lrExponent: Double = Store.double("lrExponent", -3.7) {   // 10^-3.7 ~= 2e-4
        didSet { Store.set(lrExponent, "lrExponent") }
    }
    /// Trades an encoder reload per caption window for ~285 MB of resident memory.
    @Published var evictTextEncoder: Bool = Store.bool("evictTextEncoder", true) {
        didSet { Store.set(evictTextEncoder, "evictTextEncoder") }
    }
    @Published var latentsCache: Bool = Store.bool("latentsCache", true) {
        didSet { Store.set(latentsCache, "latentsCache") }
    }

    // MARK: - derived

    var device: String? { useCPU ? "cpu" : nil }
    var learningRate: Float { Float(pow(10.0, lrExponent)) }
    var cropFrames: Int { Int((cropSeconds * SA3Engine.framesPerSecond).rounded()) }
    /// A pinned seed is clamped non-negative: libsa3 reads anything below zero as "draw a random
    /// one", so a negative value typed into the field would quietly unpin the take.
    var seed: Int64 { useManualSeed ? Int64(max(0, manualSeed)) : -1 }

    /// The adapter set for one request, in the order libsa3 should see it.
    ///
    /// `base` is the *loaded* variant where there is one: an adapter only applies to the base it
    /// was trained against, and the picker in Settings may have moved on since the load. The DiT
    /// blend contributes only what has a non-zero strength, so a slider at 0 is off without having
    /// to deselect it.
    func activeLoras(_ engine: SA3Engine) -> [(AdapterEntry, Float)] {
        let base = engine.loadedVariant ?? variant
        var out: [(AdapterEntry, Float)] = []
        if useLoras {
            for entry in engine.adapters(for: base, target: "dit") {
                let s = ditStrengths[entry.id] ?? 0
                if s > 0 { out.append((entry, Float(s))) }
            }
        }
        if let id = decoderAdapterID,
           let entry = engine.adapters(for: base, target: "decoder").first(where: { $0.id == id }) {
            out.append((entry, Float(decoderStrength)))
        }
        if let id = encoderAdapterID,
           let entry = engine.adapters(for: base, target: "encoder").first(where: { $0.id == id }) {
            out.append((entry, Float(encoderStrength)))
        }
        return out
    }

    /// Everything except the source audio and the length, which are what the three tabs differ on.
    func baseRequest(prompt: String, engine: SA3Engine) -> SA3Engine.Request {
        var r = SA3Engine.Request()
        r.prompt = prompt
        r.negativePrompt = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        r.steps = Int32(steps)
        r.seed = seed
        r.cfgScale = Float(cfgScale)
        r.distShift = distShift
        r.keepModels = keepModels
        r.loras = activeLoras(engine)
        return r
    }

    /// A slider binding for one DiT adapter. Written through the dictionary so the whole blend
    /// persists as a unit and an adapter that is later deleted simply stops being read.
    func ditStrength(_ id: String) -> Double { ditStrengths[id] ?? 0 }
    func setDitStrength(_ id: String, _ value: Double) { ditStrengths[id] = value }

    private enum Store {
        private static var d: UserDefaults { .standard }
        static func string(_ k: String, _ fallback: String) -> String { d.string(forKey: k) ?? fallback }
        static func optString(_ k: String) -> String? { d.string(forKey: k) }
        /// `object(forKey:)` rather than `double(forKey:)`: the typed accessors return 0/false for
        /// a key that was never written, which would silently replace every default with zero.
        static func double(_ k: String, _ fallback: Double) -> Double {
            if let v = d.object(forKey: k) as? Double { return v }
            if let v = d.object(forKey: k) as? Int { return Double(v) }
            return fallback
        }
        static func int(_ k: String, _ fallback: Int) -> Int { d.object(forKey: k) as? Int ?? fallback }
        static func bool(_ k: String, _ fallback: Bool) -> Bool { d.object(forKey: k) as? Bool ?? fallback }
        static func set(_ v: Any?, _ k: String) { d.set(v, forKey: k) }
        static func strengths(_ k: String) -> [String: Double] {
            d.dictionary(forKey: k) as? [String: Double] ?? [:]
        }
        static func setStrengths(_ v: [String: Double], _ k: String) { d.set(v, forKey: k) }
    }
}
