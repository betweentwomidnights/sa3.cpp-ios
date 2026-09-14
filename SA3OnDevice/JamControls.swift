import SwiftUI

/// The controls create, continue and transform share.
///
/// They are one file on purpose. The three actions differ only in their source audio and their
/// length control; everything below that — the adapter blend, the seed, the sampler — has to be
/// the same or a take stops being reproducible the moment you continue it.
enum JamControls {

    static let accent = Color.teal
    static let field = Color.white.opacity(0.09)

    // MARK: - replace / add

    /// Replace makes the performance the new take; add plays the current take underneath it and
    /// records the sum.
    ///
    /// Shared by the pads and the mic because it is one decision and deserves one shape. The two
    /// differ only in what they need from the room: pad add is inaudible to anything, mic add plays
    /// the take out loud next to an open microphone.
    enum RecordMode { case replace, add }

    /// Only worth showing when there is a take to add to — with nothing there, the two options have
    /// nothing to differ about, so both callers hide it rather than offering a dead choice.
    struct RecordModeToggle: View {
        @Binding var mode: RecordMode
        var disabled = false

        var body: some View {
            HStack(spacing: 2) {
                segment("replace", .replace)
                segment("add", .add)
            }
            .padding(2)
            .background(Color.white.opacity(0.07), in: Capsule())
            // The drawer header is tight — a running clock beside this can squeeze it until
            // "replace" wraps onto two lines. It is a two-word control with a fixed intrinsic
            // width, so it keeps that width everywhere and the row's slack comes from elsewhere.
            .fixedSize()
        }

        private func segment(_ title: String, _ value: RecordMode) -> some View {
            let on = mode == value
            return Button { mode = value } label: {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(on ? accent : Color.clear, in: Capsule())
                    .foregroundStyle(on ? Color.black : Color.secondary)
            }
            .disabled(disabled)
        }
    }

    // MARK: - prompt

    struct PromptField: View {
        let placeholder: String
        @Binding var text: String

        var body: some View {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(11)
                .background(field, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - adapter blend

    /// One slider per DiT adapter the registry holds for the loaded base.
    ///
    /// Registry-driven rather than a fixed list: a run finishes, `register` adds the adapter, and
    /// it appears here with no other wiring. Anything at 0 is simply not sent, so the blend does
    /// not need a per-adapter on/off as well as a strength.
    struct LoraBlend: View {
        @ObservedObject var settings: SA3Settings
        @ObservedObject var engine: SA3Engine

        private var base: String { engine.loadedVariant ?? settings.variant }
        private var adapters: [AdapterEntry] { engine.adapters(for: base, target: "dit") }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.useLoras) {
                    HStack(spacing: 8) {
                        Text("loras").font(.headline)
                        Text(adapters.isEmpty ? "none trained yet" : "\(adapters.count) available")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(accent)

                if settings.useLoras {
                    if adapters.isEmpty {
                        Text("train one on the train tab and it lands here automatically")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(adapters) { adapter in
                            LoraRow(adapter: adapter, settings: settings,
                                    loadedEncoding: engine.loadedVariant == nil ? nil : settings.ditEncoding)
                        }
                    }
                }
            }
        }
    }

    private struct LoraRow: View {
        let adapter: AdapterEntry
        @ObservedObject var settings: SA3Settings
        /// What the base is actually running at, when something is loaded. An adapter trained
        /// against f16 runs fine on q4 — that is the whole point of the rank decomposition — but
        /// it is worth being able to see the pairing when a take sounds off.
        let loadedEncoding: String?

        private var binding: Binding<Double> {
            Binding(get: { settings.ditStrength(adapter.id) },
                    set: { settings.setDitStrength(adapter.id, $0) })
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(adapter.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.2f", binding.wrappedValue))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: binding, in: 0...1.5, step: 0.05).tint(accent)
                Text(provenance)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        private var provenance: String {
            var parts = ["r\(adapter.rank)", "\(adapter.steps) steps", "trained on \(adapter.encoding)"]
            if let loadedEncoding, loadedEncoding != adapter.encoding {
                parts.append("running on \(loadedEncoding)")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - seed

    struct Seed: View {
        @ObservedObject var settings: SA3Settings
        @ObservedObject var engine: SA3Engine

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: $settings.useManualSeed) {
                        Text("pin the seed").font(.subheadline)
                    }
                    .tint(accent)
                }
                if settings.useManualSeed {
                    HStack {
                        TextField("seed", value: $settings.manualSeed, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(field, in: RoundedRectangle(cornerRadius: 7))
                        if let last = engine.lastSeed {
                            Button("use last") { settings.manualSeed = Int(clamping: last) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .tint(accent)
                        }
                    }
                } else {
                    Text(engine.lastSeed.map { "last seed \($0)" } ?? "last seed —")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - gain

    /// A fader, in decibels rather than a linear multiplier, so unity sits in the middle of the
    /// useful range and the numbers mean what they mean everywhere else audio is discussed.
    ///
    /// It only goes to +12, and there is no limiter behind it: boosting a full-scale take will
    /// clip on the way to 16-bit. That is the honest behaviour of a gain knob, and it is where a
    /// global limiter goes when one is wanted.
    struct GainSlider: View {
        var label = "gain"
        @Binding var decibels: Double
        var range: ClosedRange<Double> = -24...12
        var onCommit: () -> Void = {}

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.format(decibels))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(decibels > 0.05 ? Color.orange : Color.primary)
                    if abs(decibels) > 0.05 {
                        Button("unity") { decibels = 0; onCommit() }
                            .font(.caption2)
                    }
                }
                Slider(value: $decibels, in: range, step: 0.5) { editing in
                    if !editing { onCommit() }
                }
                .tint(accent)
            }
        }

        static func format(_ db: Double) -> String {
            if abs(db) < 0.05 { return "0.0 dB" }
            return String(format: "%@%.1f dB", db > 0 ? "+" : "\u{2212}", abs(db))
        }
    }

    // MARK: - advanced

    /// Steps, cfg, shift and the negative prompt. sa3 is arc-trained, so the defaults are usually
    /// right; these are here for the same reason the benchmark controls are, not for daily use.
    struct Advanced: View {
        @ObservedObject var settings: SA3Settings
        /// Only create has a canvas to pad. With init audio the source fixes the length, so the
        /// ending control would do nothing.
        var showEnding = false
        @State private var expanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation { expanded.toggle() } } label: {
                    Label("advanced", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if expanded {
                    SliderRow(label: "steps", value: Binding(
                        get: { Double(settings.steps) },
                        set: { settings.steps = Int($0) }
                    ), range: 1...24, step: 1, format: { "\(Int($0))" })

                    SliderRow(label: "cfg", value: $settings.cfgScale, range: 1...8, step: 0.1,
                              format: { String(format: "%.1f", $0) })
                    if settings.cfgScale != 1 {
                        Text("cfg above 1 runs the DiT twice per step")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("distribution shift").font(.caption).foregroundStyle(.secondary)
                        Picker("distribution shift", selection: $settings.distShift) {
                            Text("logsnr").tag("LogSNR")
                            Text("flux").tag("Flux")
                            Text("full").tag("Full")
                            Text("none").tag("None")
                        }
                        .pickerStyle(.segmented)
                    }

                    if showEnding {
                        SliderRow(label: "ending", value: $settings.durationPadding,
                                  range: 0...12, step: 1,
                                  format: { $0 == 0 ? "lands" : String(format: "+%.0fs", $0) })
                        Text("headroom the sampler gets past the requested length. 0 lets the model end the piece.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    PromptField(placeholder: "negative prompt (only with cfg)",
                                text: $settings.negativePrompt)
                }
            }
        }
    }

    // MARK: - primitives

    struct SliderRow: View {
        let label: String
        @Binding var value: Double
        let range: ClosedRange<Double>
        var step: Double = 1
        var format: (Double) -> String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(format(value)).font(.caption.monospacedDigit())
                }
                Slider(value: $value, in: range, step: step).tint(accent)
            }
        }
    }

    /// The one button each panel ends with. Disabled unless a context exists — generate against a
    /// null ctx silently does nothing, which reads as a hang.
    struct GoButton: View {
        let title: String
        let busyTitle: String
        @ObservedObject var engine: SA3Engine
        var enabled = true
        let action: () -> Void

        private var busy: Bool { if case .working = engine.status { return true }; return false }
        private var ready: Bool { engine.isLoaded && !busy && enabled }

        var body: some View {
            Button(action: action) {
                Text(busy ? busyTitle : (engine.isLoaded ? title : "load models first"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(ready ? accent : Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(ready ? Color.black : Color.secondary)
            }
            .disabled(!ready)
        }
    }
}

/// The card the three panels are presented in.
struct JamOverlay<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    let content: Content

    init(title: String, isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .transition(.opacity)

                VStack(spacing: 14) {
                    HStack {
                        Text(title).font(.title3.weight(.semibold))
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    content
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(white: 0.09))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .stroke(JamControls.accent.opacity(0.5), lineWidth: 1))
                )
                .padding(.horizontal, 18)
                .frame(maxWidth: 420)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.25)) { isPresented = false }
    }
}
