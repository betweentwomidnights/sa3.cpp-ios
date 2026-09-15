import AVFoundation
import SwiftUI
import UIKit

/// The jam tab: one current take, and three ways to move it forward.
///
/// create / continue / transform are the three V1 operations, and all end in one `generate` call on
/// the V1 table. They differ in what they hand it: nothing, a source plus seconds to add, or a
/// source to rework. The library decides the frame counts and windows from that.
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
    @StateObject private var route = AudioRoute()
    /// The overdub's count-in. Its own instance rather than the recorder's, because the two take
    /// different paths to a file and only one of them is running at a time anyway.
    @StateObject private var overdubCount = CountIn()

    @State private var showCreate = false
    @State private var showContinue = false
    @State private var showTransform = false
    @State private var showSettings = false
    @State private var showShare = false
    @State private var showMicDenied = false
    @State private var showSaveToPad = false
    @State private var showTakeEditor = false
    @State private var padsExpanded = false
    /// What the record button does. Replace goes through `RecordingManager`; add goes through the
    /// pad graph, which is the only one of the two that can play the take while the mic is open.
    @State private var micMode: JamControls.RecordMode = .replace
    @State private var micOverdub = false
    @State private var showBleedWarning = false
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
                        } else if micOverdub {
                            overdubCard
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
                              canRecord: !recorder.isActive && !micOverdub && !busy,
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
            .confirmationDialog("no headphones", isPresented: $showBleedWarning,
                                titleVisibility: .visible) {
                Button("record anyway") { beginOverdub() }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("add plays the take out loud while the mic is open, so the speaker ends up in the recording. headphones fix it.")
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
        captureCard(beat: recorder.countInBeat,
                    elapsed: String(format: "%.1fs", recorder.elapsed),
                    level: recorder.level,
                    footnote: "stops on its own at \(Int(settings.maxRecordSeconds))s",
                    running: recorder.isRecording,
                    stop: recorder.stop)
    }

    /// The overdub's card. The pad drawer keeps its recording state in its own header because the
    /// pads are the thing you are watching; here the take is, so it goes where the take card was.
    ///
    /// The length is known in advance — the take is what ends it — so the clock counts toward it
    /// rather than up toward nothing in particular.
    private var overdubCard: some View {
        captureCard(beat: overdubCount.beat,
                    elapsed: String(format: "%.1f / %.1fs", pads.recordedSeconds, sourceSeconds),
                    level: pads.micLevel,
                    footnote: "over the take — stops when it ends",
                    running: pads.recording,
                    stop: stopOverdub)
    }

    /// Both ways of capturing a take get the same card: the count, then a meter and a clock, then
    /// one button that means cancel while the count is running and stop once it is not.
    private func captureCard(beat: Int?, elapsed: String, level: Double, footnote: String,
                             running: Bool, stop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            if let beat {
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
                Text(elapsed)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                meter(level)
                Text(footnote)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button(action: stop) {
                Label(running ? "stop" : "cancel",
                      systemImage: running ? "stop.fill" : "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(running ? Color.red : Color.white.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Average power, not peak — it moves like the performance rather than flickering on every
    /// transient, which is what you want to confirm the mic is hearing you at all.
    private func meter(_ level: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(JamControls.accent)
                    .frame(width: geo.size.width * level)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
        .animation(.linear(duration: 0.05), value: level)
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
            micModeRow
        }
    }

    /// Under the record button rather than beside it: the four actions above are a grid, and a
    /// fifth control in it would unbalance them for something that only qualifies one of the four.
    ///
    /// The toggle is always here once there is a take; the triangle is the conditional part, and it
    /// is live — pull the buds out mid-jam and it appears, put them back and it goes.
    private var micModeRow: some View {
        HStack(spacing: 8) {
            Spacer()
            if effectiveMicMode == .add && !route.headphonesConnected {
                Label("needs headphones", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            JamControls.RecordModeToggle(mode: $micMode, disabled: busy)
        }
    }

    /// Add falls back to replace the moment the take it referred to is gone — the same rule the
    /// pad drawer follows, for the same reason.
    private var effectiveMicMode: JamControls.RecordMode {
        session.current == nil ? .replace : micMode
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

    /// The record button. Replace is the recorder; add is the pad graph with the mic in it, and
    /// only add has to care about the room — so only add checks the route.
    private func startRecording() {
        guard !pads.recording, !micOverdub else { return }
        guard effectiveMicMode == .add else { startReplaceRecording(); return }
        guard route.headphonesConnected else { showBleedWarning = true; return }
        beginOverdub()
    }

    /// One tap arms the recorder; the next stops it. Everything it needs comes off `settings`, the
    /// same way the three generate actions get theirs — the mic has no configuration of its own.
    private func startReplaceRecording() {
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

    /// The mic as another source into the pad graph.
    ///
    /// Replace stays on `RecordingManager` because it has nothing to play against: no monitoring,
    /// so no headphones and no feedback. Add has to hear the take to perform over it, and the tap
    /// already on the graph's main mixer is what puts the take and the mic in one file — the same
    /// tap, and the same `startRecording(over:)`, that the pads have been using all along.
    private func beginOverdub() {
        guard let take = session.url else { return }
        recorder.requestPermission { granted in
            guard granted else {
                if recorder.permission == .denied { showMicDenied = true }
                return
            }
            player.stopAndRelease()
            // A restart on `.playAndRecord`: the category has to be right before the engine comes
            // up, or the input node has no channels to connect.
            pads.start(mic: true)
            guard pads.running else { return }
            micOverdub = true
            guard settings.countIn else { captureOverdub(over: take); return }
            overdubCount.run(bpm: settings.countInBPM, beats: settings.countInBeats) {
                captureOverdub(over: take)
            }
        }
    }

    private func captureOverdub(over take: URL) {
        // The take ending is the natural end of an overdub: stopping there keeps the result the
        // same length as the source, so continue and transform behave as they did.
        let started = pads.startRecording(over: take) {
            if pads.recording { finishOverdub() }
        }
        if !started { endOverdub() }
    }

    /// Cancel while the count runs — nothing has been captured yet — and stop after it.
    private func stopOverdub() {
        if overdubCount.isRunning { endOverdub(); return }
        finishOverdub()
    }

    private func finishOverdub() {
        pads.stopRecording { url in
            endOverdub()
            guard let url else { return }
            session.beginRoot(url, source: .recording)
            player.setURL(url)
        }
    }

    /// Puts the graph back how it was found. The mic comes out and the session goes back to
    /// playback; the engine only stays up if the drawer is the one holding it open.
    private func endOverdub() {
        micOverdub = false
        overdubCount.cancel()
        pads.stop()
        if padsExpanded { pads.start() }
    }

    private func load() {
        engine.load(variant: settings.variant, encoding: settings.ditEncoding,
                    textEncoding: settings.textEncoding, aeEncoding: settings.aeEncoding,
                    device: settings.device)
    }

    private func create() {
        showCreate = false
        var request = settings.baseRequest(prompt: settings.createPrompt, engine: engine)
        request.operation = .generate
        request.durationSeconds = settings.createDuration
        request.tailPadding = Float(settings.durationPadding)
        engine.generate(request) { url in
            guard let url else { return }
            session.beginRoot(url, seed: engine.lastSeed, prompt: settings.createPrompt)
            player.setURL(url)
        }
    }

    private func continueTake() {
        guard let audio = session.url.flatMap(SA3AudioFile.planarStereo) else { return }
        showContinue = false
        player.pause()
        // Just the seconds to add. V1 places the regeneration window past the end of the source,
        // pulls it back for the splice, and trims the result to source + added — the app used to
        // compute that window itself and got to stop.
        var request = settings.baseRequest(prompt: settings.continuePrompt, engine: engine)
        request.operation = .continuation
        request.durationSeconds = settings.continueAddSeconds
        request.inputAudio = audio
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
        audio.noiseLevel = Float(settings.transformNoise)
        var request = settings.baseRequest(prompt: settings.transformPrompt, engine: engine)
        request.operation = .transform
        request.inputAudio = audio
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
                    // Seconds, and only seconds: V1 owns the conversion to latent frames and the
                    // even-frame rounding SAME-S needs, so a frame count shown here would be the
                    // app's guess at the library's arithmetic rather than what it actually used.
                    JamControls.SliderRow(label: "length", value: $settings.createDuration,
                                          range: 5...60, step: 0.5,
                                          format: { String(format: "%.1fs", $0) })
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
