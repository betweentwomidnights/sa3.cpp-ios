import SwiftUI
import AVFoundation

/// Deliberately plain. This is an instrument for finding out what an iPhone can do with sa3,
/// not a product — every control maps to one libsa3 argument, and the log is the output that
/// matters most.
struct ContentView: View {
    @EnvironmentObject var engine: SA3Engine

    @State private var prompt = "funk soul-jazz, 88 bpm, G minor"
    @State private var steps = 8.0
    @State private var trainSteps = 20.0
    @State private var seed = "42"
    @State private var player: AVAudioPlayer?
    @State private var lastOutput: URL?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                generateSection
                trainSection
                logSection
            }
            .navigationTitle("sa3 on device")
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
            HStack {
                Button("load models") { engine.load() }
                    .disabled(engine.status != .idle && !isFailed)
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
            TextField("prompt", text: $prompt, axis: .vertical).lineLimit(1...3)
            HStack {
                Text("steps \(Int(steps))").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $steps, in: 1...16, step: 1)
            }
            HStack {
                Text("seed").font(.caption).frame(width: 70, alignment: .leading)
                TextField("seed", text: $seed).keyboardType(.numbersAndPunctuation)
            }
            Button("generate") {
                engine.generate(prompt: prompt, steps: Int32(steps),
                                seed: Int64(seed) ?? -1) { url in
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
                             output: out, steps: Int32(trainSteps))
            }
            .disabled(engine.status != .ready)
            Button("cancel", role: .destructive) { engine.cancel() }
                .disabled(!isWorking)
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

    private var statusLabel: String {
        switch engine.status {
        case .idle: return "idle"
        case .loading: return "loading models…"
        case .ready: return "ready"
        case .working(let what): return what
        case .failed(let why): return "failed: \(why)"
        }
    }

    private var isFailed: Bool { if case .failed = engine.status { return true }; return false }
    private var isWorking: Bool { if case .working = engine.status { return true }; return false }

    private func play(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
