import SwiftUI

/// Everything that decides what the jam tabs are running against.
///
/// The model set lives here rather than in the tabs because it is a property of the session, not
/// of one action: create, continue and transform all go through the same loaded context, and a
/// take is only reproducible if that context did not change underneath it. The autoencoder
/// adapters are here for the same reason — they fix the decode, which every action performs.
struct SettingsView: View {
    @EnvironmentObject var engine: SA3Engine
    @EnvironmentObject var settings: SA3Settings
    @Environment(\.dismiss) private var dismiss

    @State private var storage: [(String, Int64)] = []

    /// A section to open on, for callers that send someone here for one setting — the jam view's
    /// error card sends a GPU failure to the performance section.
    var focus: Focus? = nil
    enum Focus: Hashable { case performance }

    private var busy: Bool { if case .working = engine.status { return true }; return false }
    /// `load` early-returns once a context exists, so the pickers follow the same rule: changing
    /// them while something is loaded would describe a set that is not the one running.
    private var canLoad: Bool { !engine.isLoaded && !busy }
    private var base: String { engine.loadedVariant ?? settings.variant }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    modelSection
                    performanceSection.id(Focus.performance)
                    micSection
                    autoencoderAdapterSection
                    registrySection
                    storageSection
                    logSection
                }
                .onAppear {
                    guard let focus else { return }
                    // After the first layout pass, or there is nothing to scroll to yet.
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(focus, anchor: .top) }
                    }
                }
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                }
            }
            .onAppear { storage = engine.storageReport() }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }

    // MARK: - model set

    private var modelSection: some View {
        Section("model set") {
            Group {
                Picker("variant", selection: $settings.variant) {
                    ForEach(Self.variants, id: \.self) { Text($0) }
                }
                Picker("dit", selection: $settings.ditEncoding) {
                    ForEach(Self.encodings, id: \.self) { Text($0) }
                }
                Picker("t5 encoder", selection: $settings.textEncoding) {
                    ForEach(Self.textEncodings, id: \.self) { Text($0) }
                }
                Picker("autoencoder", selection: $settings.aeEncoding) {
                    ForEach(Self.aeEncodings, id: \.self) { Text($0) }
                }
            }
            // Frozen while a set is resident: these describe what to load, and editing them then
            // would name a configuration that is not the one running.
            .disabled(!canLoad)
            // Per-request, not per-load, so it stays live with models resident.
            Toggle("keep models resident", isOn: $settings.keepModels)

            HStack {
                Button("load") {
                    engine.load(variant: settings.variant, encoding: settings.ditEncoding,
                                textEncoding: settings.textEncoding,
                                aeEncoding: settings.aeEncoding, device: settings.device)
                }
                .disabled(!canLoad)
                Spacer()
                Button("unload", role: .destructive) { engine.unload() }
                    .disabled(!engine.isLoaded || busy)
            }
            Text(statusLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - performance

    /// What to reach for when the GPU gives up on a take. The chunk is per-request, so it stays
    /// live with models resident; the backend is chosen at load, so it freezes like the model set.
    private var performanceSection: some View {
        Section {
            Picker("autoencoder chunk", selection: $settings.codecChunkFrames) {
                ForEach(Self.codecChunks, id: \.self) { frames in
                    Text(String(format: "%d frames (%.1fs)", frames,
                                Double(frames) / SA3Engine.framesPerSecond))
                }
            }
            Toggle("cpu backend", isOn: $settings.useCPU)
                .disabled(!canLoad)
        } header: {
            Text("performance")
        } footer: {
            Text("medium encodes and decodes in chunks with a quarter overlap. smaller chunks use less GPU memory at once and finish sooner, so try them first if a take fails on the GPU. the cpu backend always works, slowly, and applies at the next load. small models run whole and ignore the chunk.")
        }
    }

    private static let codecChunks = [64, 96, 128, 192, 256]

    private var statusLabel: String {
        switch engine.status {
        case .idle: return "idle"
        case .loading: return "loading…"
        case .ready: return "ready"
        case .working(let what): return what
        case .failed(let why): return "failed: \(why)"
        }
    }

    // MARK: - the mic

    /// The record button takes no arguments — one tap arms it — so everything it obeys is here.
    private var micSection: some View {
        Section {
            Toggle("noise cancellation", isOn: $settings.cancelNoise)
            Toggle("count-in", isOn: $settings.countIn)
            if settings.countIn {
                Stepper("\(settings.countInBPM) bpm", value: $settings.countInBPM,
                        in: 40...240, step: 5)
                Stepper("\(settings.countInBeats) beats", value: $settings.countInBeats, in: 1...8)
            }
            HStack {
                Text(String(format: "max length %.0fs", settings.maxRecordSeconds))
                    .frame(width: 130, alignment: .leading)
                Slider(value: $settings.maxRecordSeconds, in: 5...120, step: 5)
            }
        } header: {
            Text("microphone")
        } footer: {
            Text("noise cancellation runs Apple's voice processing — it is tuned for speech and eats the transients in a beatbox, so leave it off to perform. a recording becomes the current take, and continue and transform work on it like any other.")
        }
    }

    // MARK: - autoencoder adapters

    /// The decoder and encoder slots. Single-select, unlike the DiT blend: they touch ae.dec.* and
    /// ae.enc.*, which are disjoint from each other and from the DiT, so one of each applies in the
    /// same request as the whole DiT blend.
    ///
    /// They key on the SAME family rather than the variant — small-music and small-sfx share
    /// SAME-S, so a decoder adapter trained for one is valid for the other.
    private var autoencoderAdapterSection: some View {
        Section {
            adapterSlot(title: "decoder lora", target: "decoder",
                        selection: $settings.decoderAdapterID, strength: $settings.decoderStrength)
            adapterSlot(title: "encoder lora", target: "encoder",
                        selection: $settings.encoderAdapterID, strength: $settings.encoderStrength)
        } header: {
            Text("autoencoder adapters")
        } footer: {
            Text("applies to create, continue and transform alike. \(sa3AutoencoderFamily(for: base)) for \(base).")
        }
    }

    @ViewBuilder
    private func adapterSlot(title: String, target: String,
                             selection: Binding<String?>, strength: Binding<Double>) -> some View {
        let available = engine.adapters(for: base, target: target)
        Picker(title, selection: selection) {
            Text("none").tag(String?.none)
            ForEach(available) { Text($0.name).tag(String?.some($0.id)) }
        }
        .disabled(available.isEmpty)
        if selection.wrappedValue != nil {
            HStack {
                Text(String(format: "strength %.2f", strength.wrappedValue))
                    .font(.caption).frame(width: 110, alignment: .leading)
                Slider(value: strength, in: 0...1.5, step: 0.05)
            }
        }
    }

    // MARK: - registry

    /// Everything the app has trained or imported. A run ends, `register` copies the adapter here,
    /// and it shows up in the jam sliders with no further wiring — this section is where it can be
    /// inspected and removed again.
    private var registrySection: some View {
        Section {
            if engine.adapters.isEmpty {
                Text("nothing yet — a finished run lands here automatically")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(engine.adapters) { adapter in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(adapter.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text("\(adapter.target) · \(adapter.variant) · r\(adapter.rank) · \(adapter.steps) steps · \(adapter.encoding)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    // Resolve the entries before removing any: deleteAdapter mutates the array the
                    // offsets index into, so a multi-row delete would otherwise hit the wrong rows.
                    for entry in offsets.map({ engine.adapters[$0] }) {
                        engine.deleteAdapter(entry)
                        // A slot pointing at a deleted adapter is harmless — activeLoras simply
                        // finds nothing — but it leaves the picker showing a blank selection.
                        if settings.decoderAdapterID == entry.id { settings.decoderAdapterID = nil }
                        if settings.encoderAdapterID == entry.id { settings.encoderAdapterID = nil }
                        settings.ditStrengths.removeValue(forKey: entry.id)
                    }
                }
            }
        } header: {
            Text("adapters")
        } footer: {
            Text("swipe to delete. downloading adapters from drive or a hugging face repo is not wired up yet.")
        }
    }

    // MARK: - storage

    private var storageSection: some View {
        Section("storage") {
            ForEach(storage, id: \.0) { name, bytes in
                HStack {
                    Text(name).font(.caption)
                    Spacer()
                    Text(String(format: "%.2f GB", Double(bytes) / 1e9))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            .disabled(busy)
            Text(SA3Engine.modelsDir.path)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
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

    private static let variants = ["small-music", "small-sfx", "medium"]
    /// Every tier libsa3 accepts for the DiT. Picking one whose gguf is not side-loaded fails at
    /// load with a message naming what the directory actually holds.
    private static let encodings = ["q4_k_m", "q5_k_m", "q8_0", "f16", "f32"]
    private static let textEncodings = ["q8_0", "f16", "f32"]
    private static let aeEncodings = ["f32", "f16", "q8_0", "q5_k_m", "q4_k_m"]
}
