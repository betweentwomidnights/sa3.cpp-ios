import SwiftUI

/// The train tab.
///
/// A run outlives any reasonable attention span, so what this shows first is the run: where it is,
/// what the loss is doing, and how long the rest will take. The knobs that set a run up are real
/// and stay reachable, but they stopped being the thing the screen leads with.
struct TrainView: View {
    @EnvironmentObject var engine: SA3Engine
    @EnvironmentObject var settings: SA3Settings

    @State private var showConfig = false
    @State private var dataset = DatasetStatus.unknown

    private var busy: Bool { if case .working = engine.status { return true }; return false }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        datasetCard
                        runCard
                        configCard
                        logCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("train")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
        .onAppear { dataset = DatasetStatus.read() }
    }

    // MARK: - dataset

    private var datasetCard: some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("dataset").font(.headline)
                    Text(dataset.summary).font(.caption)
                        .foregroundStyle(dataset.ok ? Color.secondary : Color.orange)
                    Text(dataset.path).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.head)
                }
                Spacer()
                Button { dataset = DatasetStatus.read() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - the run

    private var runCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(busy ? "running" : (engine.stepHistory.isEmpty ? "idle" : "last run"))
                        .font(.headline)
                    Spacer()
                    if let s = engine.lastStep {
                        Text("\(s.step)/\(s.maxSteps)").font(.subheadline.monospacedDigit())
                    }
                }

                if busy, engine.progress > 0 {
                    ProgressView(value: min(max(engine.progress, 0), 1)).tint(JamControls.accent)
                }

                if let s = engine.lastStep {
                    HStack(spacing: 18) {
                        metric("loss", String(format: "%.4f", s.loss))
                        metric("grad", String(format: "%.3f", s.gradNorm))
                        metric("s/step", String(format: "%.2f", s.seconds))
                        metric("left", remaining)
                    }
                    LossPlot(history: engine.stepHistory)
                        .frame(height: 130)
                } else {
                    Text("no run yet. \(Int(settings.trainSteps)) steps at the current settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(action: startRun) {
                        Text("train")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(busy ? Color.white.opacity(0.12) : JamControls.accent,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(busy ? Color.secondary : Color.black)
                    }
                    // Training loads its own models on its own backend, so it does not need — and
                    // must not have — the inference context alive beside it. `train` drops it.
                    .disabled(busy || !dataset.ok)

                    Button(role: .destructive, action: engine.cancel) {
                        Text("cancel")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!busy)
                }

                if engine.isLoaded {
                    Text("starting a run unloads the inference context first")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    /// Wall clock left, from the mean of the last 20 steps rather than the whole run: the first
    /// steps carry the pre-encode and would make every estimate after them far too pessimistic.
    private var remaining: String {
        guard let s = engine.lastStep, s.maxSteps > s.step else { return "—" }
        let recent = engine.stepHistory.suffix(20)
        guard !recent.isEmpty else { return "—" }
        let mean = recent.reduce(0.0) { $0 + $1.seconds } / Double(recent.count)
        let left = mean * Double(s.maxSteps - s.step)
        if left < 90 { return String(format: "%.0fs", left) }
        return String(format: "%.0fm", left / 60)
    }

    // MARK: - configuration

    private var configCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Button { withAnimation { showConfig.toggle() } } label: {
                    HStack {
                        Text("run settings").font(.headline)
                        Spacer()
                        Text(configSummary).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: showConfig ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showConfig {
                    JamControls.SliderRow(label: "steps", value: $settings.trainSteps,
                                          range: 1...2000, step: 1, format: { "\(Int($0))" })
                    VStack(alignment: .leading, spacing: 2) {
                        JamControls.SliderRow(label: "crop", value: $settings.cropSeconds,
                                              range: 2...24, step: 0.5,
                                              format: { String(format: "%.1fs", $0) })
                        Text("\(settings.cropFrames) latent frames per crop — the backward pass holds activations for the whole crop")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    JamControls.SliderRow(label: "rank", value: $settings.rank,
                                          range: 4...32, step: 4, format: { "\(Int($0))" })
                    JamControls.SliderRow(label: "learning rate", value: $settings.lrExponent,
                                          range: -4.3 ... -3.0, step: 0.1,
                                          format: { String(format: "%.0e", pow(10.0, $0)) })
                    Toggle("evict text encoder", isOn: $settings.evictTextEncoder)
                        .font(.subheadline).tint(JamControls.accent)
                    Toggle("latents cache", isOn: $settings.latentsCache)
                        .font(.subheadline).tint(JamControls.accent)
                    Text("trains against \(settings.variant) at \(settings.ditEncoding) — change the model set in the jam tab's settings")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var configSummary: String {
        "\(Int(settings.trainSteps)) steps · r\(Int(settings.rank)) · \(String(format: "%.1fs", settings.cropSeconds))"
    }

    private var logCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("log").font(.headline)
                if engine.log.isEmpty {
                    Text("nothing yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(engine.log.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func startRun() {
        let output = SA3Engine.datasetsDir
            .deletingLastPathComponent()
            .appendingPathComponent("train-run-\(Int(Date().timeIntervalSince1970))")
        engine.train(dataset: SA3Engine.datasetsDir.appendingPathComponent("dataset"),
                     output: output, steps: Int32(settings.trainSteps),
                     variant: settings.variant, encoding: settings.ditEncoding,
                     textEncoding: settings.textEncoding, aeEncoding: settings.aeEncoding,
                     frames: Int32(settings.cropFrames), rank: Int32(settings.rank),
                     learningRate: settings.learningRate,
                     evictTextEncoder: settings.evictTextEncoder,
                     device: settings.device,
                     latentsCache: settings.latentsCache)
    }
}

/// Whether the side-loaded corpus is where sa3_train expects it.
///
/// Only the train split is checked: test and evaluation are optional, and training reads
/// `train/filelist.txt` for the item list.
struct DatasetStatus {
    var ok = false
    var summary = ""
    var path = ""

    static let unknown = DatasetStatus(ok: false, summary: "checking…", path: "")

    @MainActor
    static func read() -> DatasetStatus {
        let root = SA3Engine.datasetsDir.appendingPathComponent("dataset")
        let filelist = root.appendingPathComponent("train/filelist.txt")
        var status = DatasetStatus()
        status.path = root.path
        guard let text = try? String(contentsOf: filelist, encoding: .utf8) else {
            status.summary = "no train/filelist.txt — side-load the corpus into datasets/dataset/"
            return status
        }
        let items = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        status.ok = !items.isEmpty
        status.summary = status.ok ? "\(items.count) train items" : "train/filelist.txt is empty"
        return status
    }
}

/// Loss and gradient norm over the run, drawn by hand.
///
/// A Canvas rather than a charting framework: a 2000-step run is 2000 points, the axes never need
/// to be interactive, and downsampling to one column per pixel keeps it flat no matter how long
/// the run gets.
struct LossPlot: View {
    let history: [SA3Engine.TrainStep]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            let losses = history.map { Double($0.loss) }
            let grads = history.map { $0.gradNorm }
            let columns = max(2, min(history.count, Int(size.width)))

            context.stroke(path(losses, columns: columns, size: size),
                           with: .color(.teal), lineWidth: 1.5)
            context.stroke(path(grads, columns: columns, size: size),
                           with: .color(.orange.opacity(0.55)), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                legend("loss", .teal)
                legend("grad norm", .orange.opacity(0.7))
            }
            .font(.caption2)
            .padding(4)
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(label).foregroundStyle(.secondary)
        }
    }

    /// Each series is scaled to its own range: loss and grad norm live on different scales, and a
    /// shared axis would flatten whichever one is smaller into the baseline.
    private func path(_ values: [Double], columns: Int, size: CGSize) -> Path {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = hi - lo > 1e-9 ? hi - lo : 1
        var p = Path()
        for column in 0..<columns {
            // One column per pixel: average the steps that fall in it so a long run reads as a
            // trend rather than as noise sampled at whatever stride the width happens to give.
            let start = values.count * column / columns
            let end = max(start + 1, values.count * (column + 1) / columns)
            let slice = values[start..<min(end, values.count)]
            guard !slice.isEmpty else { continue }
            let mean = slice.reduce(0, +) / Double(slice.count)
            let x = size.width * Double(column) / Double(columns - 1)
            let y = size.height * (1 - (mean - lo) / span)
            if column == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}
