import SwiftUI
import AVFoundation
import UIKit

/// Deliberately plain. This is an instrument for finding out what an iPhone can do with sa3,
/// not a product — every control maps to one libsa3 argument, and the log is the output that
/// matters most.
struct ContentView: View {
    @EnvironmentObject var engine: SA3Engine

    /// Neither text field can dismiss its own keyboard: the prompt is multi-line so Return inserts
    /// a newline, and the seed uses a number pad, which has no return key at all. Hence explicit focus.
    private enum Field { case prompt, seed }
    @FocusState private var focusedField: Field?

    @State private var prompt = "funk soul-jazz, 88 bpm, G minor"
    @State private var variant = "small-music"
    /// Seconds of audio. Converted to latent frames at load-independent 10.767 fps. This is the
    /// knob that moves peak memory — decode allocates the whole clip at once on SAME-S.
    @State private var duration = 11.9
    @State private var steps = 8.0
    @State private var trainSteps = 20.0
    /// Training crop, in seconds. The backward pass holds activations for the whole crop, so this
    /// is the knob that decides whether a run fits at all.
    @State private var cropSeconds = 5.9
    @State private var rank = 16.0
    @State private var lrExponent = -3.7   // 10^-3.7 ~= 2e-4
    /// Trades an encoder reload per caption window for ~285 MB of resident memory. On by default
    /// here; the flag exists for exactly this case.
    @State private var evictTextEncoder = true
    @State private var seed = "42"
    /// The benchmark axes. `encoding` covers the DiT + SAME; the text encoder resolves apart from
    /// it, so it gets its own control — the useful pairing is a quantized DiT with a cheap encoder.
    @State private var encoding = "q4_k_m"
    @State private var textEncoding = "q8_0"
    /// The autoencoder resolves apart from `encoding` as of the ae-lora work. It used to ride on
    /// that field, so every quantized DiT quietly got a quantized SAME too.
    @State private var aeEncoding = "f32"
    /// Forces the CPU backend. Slow, but it isolates a Metal fault from a bug in the path itself —
    /// the SAME-L encode graph is shared by pre-encode and audio2audio's init_audio.
    @State private var useCPU = false
    /// Per-request residency. Frugal trades a reload (~0.5-1.5s) for a much lower peak, which is
    /// what decides whether the heavier encodings survive on a 4 GB phone.
    @State private var keepModels = true
    /// Selected adapter id, or nil for the base model. Held as an id rather than the entry so a
    /// registry reload (or a deletion) cannot leave a stale struct selected.
    @State private var loraID: String?
    @State private var loraStrength = 1.0
    /// Decoder adapters are a separate slot, not an alternative: libsa3 routes by each gguf's own
    /// lora.target, so a DiT adapter and a decoder adapter apply in the same request.
    @State private var decoderID: String?
    @State private var decoderStrength = 1.0
    /// Encoder adapters touch ae.enc.* where decoder ones touch ae.dec.* — disjoint tensors, so
    /// both can be merged in the same request alongside a DiT adapter.
    @State private var encoderID: String?
    @State private var encoderStrength = 1.0
    @State private var player: AVAudioPlayer?
    @State private var lastOutput: URL?
    @State private var storage: [(String, Int64)] = []

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                generateSection
                trainSection
                storageSection
                logSection
            }
            .navigationTitle("sa3 on device")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done") { dismissKeyboard() }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("engine") {
            HStack {
                Text(statusLabel).font(.callout)
                Spacer()
                if case .working = engine.status { ProgressView() }
            }
            if case .working = engine.status, engine.progress > 0 {
                ProgressView(value: min(max(engine.progress, 0), 1))
            }
            Picker("variant", selection: $variant) {
                ForEach(Self.variants, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .disabled(!canLoad)
            Picker("dit", selection: $encoding) {
                ForEach(Self.encodings, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .disabled(!canLoad)
            Picker("t5 encoder", selection: $textEncoding) {
                ForEach(Self.textEncodings, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .disabled(!canLoad)
            Picker("autoencoder", selection: $aeEncoding) {
                ForEach(Self.aeEncodings, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
            .disabled(!canLoad)
            Toggle("cpu backend", isOn: $useCPU)
                .font(.caption)
                .disabled(!canLoad)
            HStack {
                Button("load models") {
                    engine.load(variant: variant, encoding: encoding,
                                textEncoding: textEncoding, aeEncoding: aeEncoding,
                                device: useCPU ? "cpu" : nil)
                }
                .disabled(!canLoad)
                Spacer()
                Button("unload", role: .destructive) { engine.unload() }
                    .disabled(engine.status != .ready)
            }
            Text(SA3Engine.modelsDir.path)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var generateSection: some View {
        Section("generate") {
            // Single line on purpose. axis:.vertical turns Return into a paragraph break, which is
            // meaningless for a prompt and leaves the field with no way to dismiss its keyboard.
            TextField("prompt", text: $prompt)
                .focused($focusedField, equals: .prompt)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }
            HStack {
                Text("\(String(format: "%.1f", duration))s").font(.caption)
                    .frame(width: 70, alignment: .leading)
                Slider(value: $duration, in: 5...60, step: 0.5)
            }
            Text("\(frames) latent frames")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("steps \(Int(steps))").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $steps, in: 1...16, step: 1)
            }
            HStack {
                Text("seed").font(.caption).frame(width: 70, alignment: .leading)
                TextField("seed", text: $seed)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focusedField, equals: .seed)
                    .submitLabel(.done)
                    .onSubmit { dismissKeyboard() }
            }
            Picker("dit lora", selection: $loraID) {
                Text("none").tag(String?.none)
                ForEach(applicableAdapters) { a in
                    Text(a.name).tag(String?.some(a.id))
                }
            }
            .pickerStyle(.menu)
            if selectedAdapter != nil {
                HStack {
                    Text("strength \(String(format: "%.2f", loraStrength))").font(.caption)
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $loraStrength, in: 0...1.5, step: 0.05)
                }
            }
            Picker("decoder lora", selection: $decoderID) {
                Text("none").tag(String?.none)
                ForEach(applicableDecoders) { a in
                    Text(a.name).tag(String?.some(a.id))
                }
            }
            .pickerStyle(.menu)
            if selectedDecoder != nil {
                HStack {
                    Text("strength \(String(format: "%.2f", decoderStrength))").font(.caption)
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $decoderStrength, in: 0...1.5, step: 0.05)
                }
            }
            if !applicableEncoders.isEmpty {
                Picker("encoder lora", selection: $encoderID) {
                    Text("none").tag(String?.none)
                    ForEach(applicableEncoders) { a in
                        Text(a.name).tag(String?.some(a.id))
                    }
                }
                .pickerStyle(.menu)
                if selectedEncoder != nil {
                    HStack {
                        Text("strength \(String(format: "%.2f", encoderStrength))").font(.caption)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $encoderStrength, in: 0...1.5, step: 0.05)
                    }
                }
            }
            Toggle("keep models resident", isOn: $keepModels)
                .font(.caption)
            Button("generate") {
                dismissKeyboard()
                engine.generate(prompt: prompt, steps: Int32(steps),
                                seed: Int64(seed) ?? -1,
                                frames: Int32(frames),
                                keepModels: keepModels,
                                loras: activeLoras) { url in
                    lastOutput = url
                }
            }
            .disabled(engine.status != .ready)
            if let lastOutput {
                Button("play \(lastOutput.lastPathComponent)") { play(lastOutput) }
            }
        }
    }

    private var trainSection: some View {
        Section("train a lora") {
            HStack {
                Text("steps \(Int(trainSteps))").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $trainSteps, in: 1...200, step: 1)
            }
            HStack {
                Text("crop \(String(format: "%.1f", cropSeconds))s").font(.caption)
                    .frame(width: 70, alignment: .leading)
                Slider(value: $cropSeconds, in: 2...24, step: 0.5)
            }
            HStack {
                Text("rank \(Int(rank))").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $rank, in: 4...32, step: 4)
            }
            HStack {
                Text("lr \(lrLabel)").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $lrExponent, in: -4.3 ... -3.0, step: 0.1)
            }
            Text("\(cropFrames) latent frames per crop")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("evict text encoder", isOn: $evictTextEncoder)
                .font(.caption)
            if let s = engine.lastStep {
                VStack(alignment: .leading, spacing: 2) {
                    Text("step \(s.step)/\(s.maxSteps)  loss \(String(format: "%.4f", s.loss))")
                    Text("gnorm \(String(format: "%.3f", s.gradNorm))  \(String(format: "%.2f", s.seconds))s/step")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption, design: .monospaced))
            }
            Button("train") {
                let out = SA3Engine.datasetsDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("train-run-\(Int(Date().timeIntervalSince1970))")
                engine.train(dataset: SA3Engine.datasetsDir.appendingPathComponent("dataset"),
                             output: out, steps: Int32(trainSteps),
                             variant: variant, encoding: encoding, textEncoding: textEncoding,
                             aeEncoding: aeEncoding,
                             frames: Int32(cropFrames), rank: Int32(rank),
                             learningRate: Float(pow(10.0, lrExponent)),
                             evictTextEncoder: evictTextEncoder,
                             device: useCPU ? "cpu" : nil)
            }
            // Training does not need models loaded -- it loads its own. Requiring .ready forced a
            // second Metal backend to exist alongside it for the whole run.
            .disabled(isWorking)
            Button("cancel", role: .destructive) { engine.cancel() }
                .disabled(!isWorking)
        }
    }

    private var storageSection: some View {
        Section("storage") {
            ForEach(storage, id: \.0) { name, bytes in
                HStack {
                    Text(name).font(.caption)
                    Spacer()
                    Text(String(format: "%.2f GB", Double(bytes) / 1e9))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("empty trash") {
                    engine.emptyTrash(); storage = engine.storageReport()
                }
                Spacer()
                Button("prune runs") {
                    engine.pruneTrainRuns(); storage = engine.storageReport()
                }
            }
            .font(.caption)
            .disabled(isWorking)
        }
        .onAppear { storage = engine.storageReport() }
    }

    private var logSection: some View {
        Section("log") {
            if engine.log.isEmpty {
                Text("nothing yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(engine.log.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption2, design: .monospaced))
                }
            }
        }
    }

    private var statusLabel: String {
        switch engine.status {
        case .idle: return "idle"
        case .loading: return "loading models…"
        case .ready: return "ready"
        case .working(let what): return what
        case .failed(let why): return "failed: \(why)"
        }
    }

    private static let variants = ["small-music", "small-sfx", "medium"]

    /// An adapter only applies to the base it was trained against, so this filters on what is
    /// actually loaded — not on the variant picker, which may have moved on since.
    /// Filter on what is loaded when something is, else on what is selected — otherwise the lists
    /// go empty the moment a training run ends, since training unloads the inference context.
    /// Generate is gated on .ready regardless, so a selection made before loading is harmless.
    /// Clears SwiftUI focus and resigns first responder. @FocusState alone has been unreliable
    /// here — the keyboard toolbar does not always appear — so this also goes through UIKit.
    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private var adapterBase: String { engine.loadedVariant ?? variant }

    private var applicableAdapters: [AdapterEntry] {
        engine.adapters(for: adapterBase, target: "dit")
    }

    /// Decoder adapters key on the SAME family, so a same-s one is offered for both small variants.
    private var applicableDecoders: [AdapterEntry] {
        engine.adapters(for: adapterBase, target: "decoder")
    }

    private var selectedAdapter: AdapterEntry? {
        guard let loraID else { return nil }
        return applicableAdapters.first { $0.id == loraID }
    }

    private var applicableEncoders: [AdapterEntry] {
        engine.adapters(for: adapterBase, target: "encoder")
    }

    private var selectedDecoder: AdapterEntry? {
        guard let decoderID else { return nil }
        return applicableDecoders.first { $0.id == decoderID }
    }

    private var selectedEncoder: AdapterEntry? {
        guard let encoderID else { return nil }
        return applicableEncoders.first { $0.id == encoderID }
    }

    private var activeLoras: [(AdapterEntry, Float)] {
        var out: [(AdapterEntry, Float)] = []
        if let a = selectedAdapter { out.append((a, Float(loraStrength))) }
        if let d = selectedDecoder { out.append((d, Float(decoderStrength))) }
        if let e = selectedEncoder { out.append((e, Float(encoderStrength))) }
        return out
    }

    private var cropFrames: Int { Int((cropSeconds * SA3Engine.framesPerSecond).rounded()) }
    private var lrLabel: String { String(format: "%.0e", pow(10.0, lrExponent)) }

    /// libsa3 takes latent frames, not seconds, so convert at the shared 10.767 fps.
    private var frames: Int { Int((duration * SA3Engine.framesPerSecond).rounded()) }

    /// Published tiers. Picking one whose gguf was never side-loaded fails at load with a message
    /// naming what the directory actually holds, which is the answer you wanted anyway.
    // Every tier libsa3 accepts for the DiT. Picking one whose gguf is not side-loaded fails at
    // load with a message naming what the directory actually holds.
    private static let encodings = ["q4_k_m", "q5_k_m", "q8_0", "f16", "f32"]
    private static let textEncodings = ["q8_0", "f16", "f32"]
    private static let aeEncodings = ["f32", "f16", "q8_0", "q5_k_m", "q4_k_m"]

    /// load() early-returns once a context exists, so the controls follow the same rule.
    private var canLoad: Bool { engine.status == .idle || isFailed }

    private var isFailed: Bool { if case .failed = engine.status { return true }; return false }
    private var isWorking: Bool { if case .working = engine.status { return true }; return false }

    private func play(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
