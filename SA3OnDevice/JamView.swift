import AVFoundation
import SwiftUI
import UIKit

/// The jam tab: one current take, and three ways to move it forward.
///
/// create / continue / transform all end in `sa3_generate_ex`. create is text2music; continue is
/// an inpaint window past the end of the source; transform is audio2audio over the whole thing.
/// Everything they need beyond that comes from `SA3Settings`, which is why the three panels look
/// the same below their first control.
struct JamView: View {
    @EnvironmentObject var engine: SA3Engine
    @EnvironmentObject var settings: SA3Settings

    @StateObject private var session = TakeSession()
    @StateObject private var player = AudioPlayerManager()
    @StateObject private var recorder = RecordingManager()
    @StateObject private var library = SampleLibrary()
    @StateObject private var pads = PadEngine()

    @State private var showCreate = false
    @State private var showContinue = false
    @State private var showTransform = false
    @State private var showSettings = false
    @State private var showShare = false
    @State private var showMicDenied = false
    @State private var showSaveToPad = false
    @State private var showTakeEditor = false
    @State private var padsExpanded = false
    /// A Button reports its tap on release, so the long press below fires first and the tap
    /// follows it. Recording when the hold fired lets the button swallow that trailing tap without
    /// a flag that stays set — if SwiftUI ever declines to deliver the tap, a stuck flag would eat
    /// the next real one instead.
    @State private var shareHeldAt: Date?

    private var busy: Bool { if case .working = engine.status { return true }; return false }
    private var sourceSeconds: Double { session.url.map(SA3AudioFile.duration) ?? 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        engineBar
                        if recorder.isActive {
                            recordingCard
                        } else if session.current != nil {
                            takeCard
                            takeActions
                        } else {
                            startState
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                // safeAreaInset rather than an overlay: the drawer then reserves its own height,
                // so an open bank scrolls the take up instead of sitting on top of the transport.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PadDrawer(library: library, pads: pads, expanded: $padsExpanded,
                              canRecord: !recorder.isActive && !busy,
                              takeURL: session.url,
                              onWillRecord: { player.stopAndRelease() }) { url in
                        // Both modes land here. Replace makes the performance the take; add makes
                        // the sum of the two the take. Either way the take it displaced is one
                        // undo away, which is what makes an overdub safe to try.
                        session.beginRoot(url, source: .pads)
                        player.setURL(url)
                    }
                }

                if busy { progressCard }

                JamOverlay(title: "create", isPresented: $showCreate) {
                    CreatePanel(settings: settings, engine: engine, action: create)
                }
                JamOverlay(title: "continue", isPresented: $showContinue) {
                    ContinuePanel(settings: settings, engine: engine,
                                  sourceSeconds: sourceSeconds, action: continueTake)
                }
                JamOverlay(title: "transform", isPresented: $showTransform) {
                    TransformPanel(settings: settings, engine: engine,
                                   sourceSeconds: sourceSeconds, action: transformTake)
                }
            }
            .navigationTitle("jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("the mic is off", isPresented: $showMicDenied) {
                Button("open settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("not now", role: .cancel) {}
            } message: {
                Text("recording needs microphone access. turn it on for SA3OnDevice in the Settings app.")
            }
            .sheet(isPresented: $showShare) {
                if let url = session.url { ShareSheet(items: [url]) }
            }
            .sheet(isPresented: $showTakeEditor, onDismiss: {
                // The editor auditions through the pad graph, so it starts the engine. Hand it
                // back only if the drawer is not the one holding it open.
                if !padsExpanded { pads.stop() }
            }) {
                if let take = session.current {
                    TakeEditor(take: take, pads: pads) { url in
                        session.applyDerived(url, source: .edit, seed: take.seed,
                                             prompt: take.prompt)
                        player.setURL(url)
                    }
                }
            }
            .sheet(isPresented: $showSaveToPad) {
                if let take = session.current {
                    SaveToPadSheet(library: library, take: take) { padsExpanded = true }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }

    // MARK: - engine state

    /// What is loaded, and the one action that changes it. Deliberately a strip rather than a
    /// section: which gguf set is resident decides what every control below can do, so it should
    /// be visible without opening Settings, but the pickers themselves belong there.
    private var engineBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.isLoaded ? JamControls.accent : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.loadedVariant ?? settings.variant)
                    .font(.subheadline.weight(.medium))
                Text(engine.isLoaded
                     ? "\(settings.ditEncoding) · t5 \(settings.textEncoding) · ae \(settings.aeEncoding)"
                     : "nothing loaded")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.isLoaded {
                Button("unload") { engine.unload() }
                    .font(.caption).buttonStyle(.bordered).disabled(busy)
            } else {
                Button("load") { load() }
                    .font(.caption).buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - no take yet

    /// The two ways a jam starts: describe it, or play it. Record is the plainer button of the two
    /// only because create is the one that needs models loaded — the mic works either way, which is
    /// the whole reason it is here.
    private var startState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("nothing yet").font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                Button { showCreate = true } label: {
                    Text("create")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 28).padding(.vertical, 18)
                        .background(JamControls.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .disabled(busy)

                Button(action: startRecording) {
                    Label("record", systemImage: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 18)
                        .background(Color.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(busy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 380)
    }

    // MARK: - recording

    /// Takes the take card's place for the length of a recording, count-in included. A card rather
    /// than a sheet because the engine strip above it stays useful: you can see what will be
    /// loaded to continue whatever you are about to play.
    private var recordingCard: some View {
        VStack(spacing: 16) {
            if let beat = recorder.countInBeat {
                Text("\(beat)")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .foregroundStyle(JamControls.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: beat)
                Text("count-in · \(settings.countInBPM) bpm · \(settings.countInBeats) beats")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 40)).foregroundStyle(.red)
                Text(String(format: "%.1fs", recorder.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                meter
                Text("stops on its own at \(Int(settings.maxRecordSeconds))s")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button(action: recorder.stop) {
                Label(recorder.isRecording ? "stop" : "cancel",
                      systemImage: recorder.isRecording ? "stop.fill" : "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(recorder.isRecording ? Color.red : Color.white.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Average power, not peak — it moves like the performance rather than flickering on every
    /// transient, which is what you want to confirm the mic is hearing you at all.
    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(JamControls.accent)
                    .frame(width: geo.size.width * recorder.level)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
        .animation(.linear(duration: 0.05), value: recorder.level)
    }

    // MARK: - the take

    private var takeCard: some View {
        VStack(spacing: 14) {
            WaveformView(id: player.id, url: session.url, onSeek: { player.seek(to: $0) })
                .frame(height: 150)
                // A new take is a new render. Without this FDWaveformView is reused across a very
                // different file and the old peaks linger under the new playhead.
                .id(session.current?.id)
                // On the waveform rather than in the transport row: it acts on the audio you are
                // looking at, and the row below is about playing the take, not changing it.
                .overlay(alignment: .topTrailing) {
                    Button {
                        player.pause()
                        showTakeEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .padding(6)
                    .disabled(busy)
                }

            HStack {
                Text(takeSummary)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.stop() } label: { Image(systemName: "stop.fill") }
                Button {
                    if let t = shareHeldAt, Date().timeIntervalSince(t) < 1 { return }
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        shareHeldAt = Date()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showSaveToPad = true
                    }
                )
                Button {
                    player.stopAndRelease()
                    session.clear()
                } label: { Image(systemName: "trash") }
                if session.canUndo {
                    Button {
                        session.undo()
                        player.setURL(session.url)
                    } label: { Image(systemName: "arrow.uturn.backward") }
                }
            }
            .font(.title3)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var takeSummary: String {
        guard let take = session.current else { return "" }
        var parts = [take.source.label, String(format: "%.1fs", sourceSeconds)]
        if let seed = take.seed { parts.append("seed \(seed)") }
        if session.canUndo { parts.append("\(session.undoStack.count) back") }
        return parts.joined(separator: " · ")
    }

    /// Two rows rather than one: the top pair carries the current take forward, the bottom pair
    /// replaces it. Four across would fit on paper and read as one undifferentiated strip.
    private var takeActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                actionButton("continue") { showContinue = true }
                actionButton("transform") { showTransform = true }
            }
            HStack(spacing: 12) {
                actionButton("create") { showCreate = true }
                // The only action that does not go through libsa3, so it stays live with nothing
                // loaded — record first, load the models while you listen back.
                actionButton("record", icon: "mic.fill", needsEngine: false, action: startRecording)
            }
        }
    }

    private func actionButton(_ title: String, icon: String? = nil, needsEngine: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Label(title, systemImage: icon) } else { Text(title) }
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(busy || (needsEngine && !engine.isLoaded))
    }

    // MARK: - progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusLabel).font(.footnote)
                Spacer()
                Text("\(Int(engine.progress * 100))%").font(.footnote.monospacedDigit())
            }
            ProgressView(value: min(max(engine.progress, 0), 1)).tint(JamControls.accent)
            Button("cancel", role: .destructive) { engine.cancel() }
                .font(.footnote.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(JamControls.accent.opacity(0.5)))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
    }

    private var statusLabel: String {
        if case .working(let what) = engine.status { return what }
        return "working"
    }

    // MARK: - actions

    /// One tap arms the recorder; the next stops it. Everything it needs comes off `settings`, the
    /// same way the three generate actions get theirs — the mic has no configuration of its own.
    private func startRecording() {
        guard !pads.recording else { return }
        player.stopAndRelease()
        // The recorder takes the audio session over and deactivates it when it is done, which
        // would strand the pad engine on a dead session. Recording pad output into a take is the
        // next thing to build; until then the two simply take turns.
        pads.stop()
        recorder.countInEnabled = settings.countIn
        recorder.bpm = settings.countInBPM
        recorder.beats = settings.countInBeats
        recorder.cancelNoise = settings.cancelNoise
        recorder.maxSeconds = settings.maxRecordSeconds
        recorder.start { url in
            guard let url else {
                // nil is a refusal, a cancelled count-in, or a failed capture. Only the first has
                // anything to say, and it is the one the user can act on.
                if recorder.permission == .denied { showMicDenied = true }
                if padsExpanded { pads.start() }
                return
            }
            session.beginRoot(url, source: .recording)
            player.setURL(url)
            if padsExpanded { pads.start() }
        }
    }

    private func load() {
        engine.load(variant: settings.variant, encoding: settings.ditEncoding,
                    textEncoding: settings.textEncoding, aeEncoding: settings.aeEncoding,
                    device: settings.device)
    }

    private func create() {
        showCreate = false
        var request = settings.baseRequest(prompt: settings.createPrompt, engine: engine)
        request.frames = Int32(settings.createFrames)
        request.durationPadding = Float(settings.durationPadding)
        engine.generate(request) { url in
            guard let url else { return }
            session.beginRoot(url, seed: engine.lastSeed, prompt: settings.createPrompt)
            player.setURL(url)
        }
    }

    private func continueTake() {
        guard var audio = session.url.flatMap(SA3AudioFile.planarStereo) else { return }
        showContinue = false
        player.pause()
        let seconds = Double(audio.frameCount) / Double(audio.sampleRate)
        // The window past the end of the source is what gets regenerated; everything before it is
        // held fixed by the local conditioning, so the take continues rather than restarting.
        audio.mode = .continuation
        audio.inpaintStart = Float(seconds)
        audio.inpaintEnd = Float(seconds + settings.continueAddSeconds)
        var request = settings.baseRequest(prompt: settings.continuePrompt, engine: engine)
        request.initAudio = audio
        engine.generate(request) { url in
            guard let url else { return }
            session.applyDerived(url, source: .continuation, seed: engine.lastSeed,
                                 prompt: settings.continuePrompt)
            player.setURL(url)
        }
    }

    private func transformTake() {
        guard var audio = session.url.flatMap(SA3AudioFile.planarStereo) else { return }
        showTransform = false
        player.pause()
        audio.mode = .transform
        audio.noiseLevel = Float(settings.transformNoise)
        var request = settings.baseRequest(prompt: settings.transformPrompt, engine: engine)
        request.initAudio = audio
        engine.generate(request) { url in
            guard let url else { return }
            session.applyDerived(url, source: .transformation, seed: engine.lastSeed,
                                 prompt: settings.transformPrompt)
            player.setURL(url)
        }
    }
}

// MARK: - panels

private struct CreatePanel: View {
    @ObservedObject var settings: SA3Settings
    @ObservedObject var engine: SA3Engine
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    JamControls.PromptField(placeholder: "describe what to make",
                                            text: $settings.createPrompt)
                    VStack(alignment: .leading, spacing: 2) {
                        JamControls.SliderRow(label: "length", value: $settings.createDuration,
                                              range: 5...60, step: 0.5,
                                              format: { String(format: "%.1fs", $0) })
                        Text("\(settings.createFrames) latent frames")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    JamControls.LoraBlend(settings: settings, engine: engine)
                    JamControls.Seed(settings: settings, engine: engine)
                    JamControls.Advanced(settings: settings, showEnding: true)
                }
            }
            .frame(maxHeight: 420)
            JamControls.GoButton(title: "go", busyTitle: "creating…", engine: engine, action: action)
        }
    }
}

private struct ContinuePanel: View {
    @ObservedObject var settings: SA3Settings
    @ObservedObject var engine: SA3Engine
    let sourceSeconds: Double
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    JamControls.PromptField(placeholder: "where should it go next",
                                            text: $settings.continuePrompt)
                    VStack(alignment: .leading, spacing: 2) {
                        JamControls.SliderRow(label: "add", value: $settings.continueAddSeconds,
                                              range: 2...60, step: 0.5,
                                              format: { String(format: "%.1fs", $0) })
                        Text(String(format: "%.1fs source + %.1fs new = %.1fs",
                                    sourceSeconds, settings.continueAddSeconds,
                                    sourceSeconds + settings.continueAddSeconds))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // Continuation is an inpaint, so it needs a DiT carrying local-cond weights.
                    // Every published DiT does (dit.local_dim = 257), which is why this is not a
                    // gate — but a hand-built gguf without them fails with exactly that message.
                    //
                    // Like transform, it round-trips the source through the autoencoder, so the
                    // decoder adapter matters here for the same reason.
                    if settings.decoderAdapterID == nil {
                        Text("no decoder lora selected — the source is re-encoded, and the artefacts compound with each pass")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    JamControls.LoraBlend(settings: settings, engine: engine)
                    JamControls.Seed(settings: settings, engine: engine)
                    JamControls.Advanced(settings: settings)
                }
            }
            .frame(maxHeight: 420)
            JamControls.GoButton(title: "go", busyTitle: "continuing…", engine: engine,
                                 enabled: sourceSeconds > 0, action: action)
        }
    }
}

private struct TransformPanel: View {
    @ObservedObject var settings: SA3Settings
    @ObservedObject var engine: SA3Engine
    let sourceSeconds: Double
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    JamControls.PromptField(placeholder: "describe the transformed audio",
                                            text: $settings.transformPrompt)
                    VStack(alignment: .leading, spacing: 2) {
                        JamControls.SliderRow(label: "init noise", value: $settings.transformNoise,
                                              range: 0.05...1, step: 0.01,
                                              format: { String(format: "%.2f", $0) })
                        Text("low keeps the source, high replaces it. output stays \(String(format: "%.1fs", sourceSeconds)).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // Every transform round-trips the autoencoder, and the squeak that introduces
                    // compounds. The decoder adapter in Settings is what that was trained to fix.
                    if settings.decoderAdapterID == nil {
                        Text("no decoder lora selected — re-encoding artefacts compound on each pass")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    JamControls.LoraBlend(settings: settings, engine: engine)
                    JamControls.Seed(settings: settings, engine: engine)
                    JamControls.Advanced(settings: settings)
                }
            }
            .frame(maxHeight: 420)
            JamControls.GoButton(title: "go", busyTitle: "transforming…", engine: engine,
                                 enabled: sourceSeconds > 0, action: action)
        }
    }
}
