import SwiftUI
import UIKit

/// The pad bank, as a drawer over the bottom of the jam tab.
///
/// A drawer rather than a sheet on purpose: the point is playing pads *against* the take, so the
/// waveform and transport above have to stay visible and usable while the pads are open.
///
/// Hold-to-play is the pad's whole gesture, which leaves nothing for "open this pad" — a long
/// press is already a long note. The pencil in the header is that second gesture: in edit mode a
/// tap opens a pad instead of sounding it, and the pads visibly change to say so.
struct PadDrawer: View {
    @ObservedObject var library: SampleLibrary
    @ObservedObject var pads: PadEngine
    @Binding var expanded: Bool
    /// Whether the jam tab can take a new take right now. False while the mic has the session.
    let canRecord: Bool
    /// The current take. Its presence is what makes "add" available at all, and in add mode it is
    /// what gets played into the mix.
    let takeURL: URL?
    /// Silences the tab's own take player before a recording starts. In add mode the take comes
    /// out of the pad graph instead, and hearing both at once is a flam.
    let onWillRecord: () -> Void
    let onRecorded: (URL) -> Void

    /// The count-in, the max length and the tempo all come from the same place the microphone
    /// reads them, so the two ways of making a take behave the same.
    @EnvironmentObject var settings: SA3Settings
    @StateObject private var countIn = CountIn()
    @State private var editing = false
    @State private var mode: JamControls.RecordMode = .replace
    @State private var picking: PadSlot?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded { grid }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
        // Nothing is read off disk until the drawer opens. The collapsed bar is present from
        // launch, and decoding eight samples for a bank nobody has opened is a hitch on the jam
        // tab's first frame.
        .onChange(of: library.pads) { _, _ in if expanded { syncVoices() } }
        // Also on the samples themselves: turning the release knob has to reach the voice that is
        // already loaded, or you would be dialling it in against the old value.
        .onChange(of: library.samples) { _, _ in if expanded { syncVoices() } }
        .onChange(of: expanded) { _, open in
            if open {
                syncVoices()
                pads.start()
            } else {
                countIn.cancel()
                pads.stop()
                editing = false
            }
        }
        .onChange(of: pads.recordedSeconds) { _, elapsed in
            if pads.recording, elapsed >= settings.maxRecordSeconds { toggleRecording() }
        }
        .sheet(item: $picking) { slot in
            SamplePicker(library: library, pads: pads, slot: slot.id)
        }
    }

    // MARK: - header

    private var header: some View {
        // 10 rather than 14: recording puts seven items in this row — title, mode, clock, record,
        // edit, chevron and the spacer between them — and the gaps were the widest thing in it.
        HStack(spacing: 10) {
            Text("pads")
                .font(.subheadline.weight(.semibold))
            if expanded && takeURL != nil {
                // The count is only worth showing when the grid is not: expanded, you can see
                // which pads are filled, and this is the more useful thing to put here.
                modeToggle
            } else {
                Text(filledCount == 0 ? "empty" : "\(filledCount) of \(SampleLibrary.padCount)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if expanded {
                if let beat = countIn.beat {
                    Text("\(beat)")
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(JamControls.accent)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.12), value: beat)
                } else if pads.recording {
                    Text(elapsedLabel)
                        // Smaller than the rest of the header, and held to one line: in add mode
                        // this carries two numbers and a unit, and it is the widest thing here.
                        .font(.caption2.monospacedDigit()).foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button(action: toggleRecording) {
                    Image(systemName: armed ? "stop.fill" : "record.circle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(pads.recording ? Color.red
                                    : countIn.isRunning ? Color.white.opacity(0.22)
                                    : Color.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .disabled(!canRecord || filledCount == 0)
                Button { editing.toggle() } label: {
                    Image(systemName: "pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(editing ? Color.black : Color.secondary)
                        .padding(6)
                        .background(editing ? JamControls.accent : Color.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .disabled(armed)
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !armed { expanded.toggle() } }
        // Flick the header rather than aiming at the chevron; the drawer is meant to be opened
        // mid-jam, with the hand that is not holding the phone still.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -20 { expanded = true }
                    if value.translation.height > 20, !armed { expanded = false }
                }
        )
    }

    // MARK: - grid

    private var grid: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<SampleLibrary.padCount, id: \.self) { slot in
                    PadButton(sample: library.sample(onPad: slot),
                              seconds: library.playingSeconds(onPad: slot),
                              held: pads.held.contains(slot),
                              editing: editing,
                              onPress: { pads.press(slot) },
                              onRelease: { pads.release(slot) },
                              onOpen: { picking = PadSlot(id: slot) })
                }
            }
            Text(hint)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var filledCount: Int { library.filledCount }

    /// Counting is a state you can back out of: the second tap cancels the count rather than
    /// stopping a recording that has not started.
    private func toggleRecording() {
        if countIn.isRunning {
            countIn.cancel()
            return
        }
        if pads.recording {
            finish()
            return
        }
        guard settings.countIn else {
            begin()
            return
        }
        countIn.run(bpm: settings.countInBPM, beats: settings.countInBeats, then: begin)
    }

    private func begin() {
        onWillRecord()
        // In add mode the take ending is the natural end of the overdub: stopping there keeps the
        // result the same length as the source, so continue and transform behave as they did.
        pads.startRecording(over: effectiveMode == .add ? takeURL : nil) {
            if pads.recording { finish() }
        }
    }

    private func finish() {
        pads.stopRecording { url in
            guard let url else { return }
            onRecorded(url)
        }
    }

/// Add falls back to replace the moment the take it referred to is gone.
    private var effectiveMode: JamControls.RecordMode { takeURL == nil ? .replace : mode }

    private var modeToggle: some View {
        JamControls.RecordModeToggle(mode: $mode, disabled: armed)
    }

    /// In add mode the length is known in advance, so show the target rather than a number that
    /// climbs toward nothing in particular.
    private var elapsedLabel: String {
        guard effectiveMode == .add, let takeURL else {
            return String(format: "%.1fs", pads.recordedSeconds)
        }
        return String(format: "%.1f/%.1fs", pads.recordedSeconds, SA3AudioFile.duration(takeURL))
    }

    /// Recording, or about to be. Everything that must not move mid-take keys off this rather
    /// than off `pads.recording`, which is still false while the count runs.
    private var armed: Bool { pads.recording || countIn.isRunning }

    private var hint: String {
        if countIn.isRunning { return "counting you in…" }
        if pads.recording {
            return effectiveMode == .add ? "playing over the take — stops when it ends"
                                         : "playing into a new take — stop to keep it"
        }
        if editing { return "tap a pad to fill or clear it" }
        if filledCount == 0 { return "hold the share button on a take to save it here" }
        return "hold a pad to play it"
    }

    /// Pushes the library's assignments into the engine. Cheap to call repeatedly — `load` keeps
    /// the buffer when the pad already holds that sample, so a reassignment of one pad does not
    /// re-read the other seven off disk.
    private func syncVoices() {
        for slot in 0..<SampleLibrary.padCount {
            pads.load(library.sample(onPad: slot), settings: library.pad(slot), onPad: slot)
        }
    }
}

// MARK: - one pad

private struct PadButton: View {
    let sample: Sample?
    /// What this pad plays, which is the window when there is one — not the file's length.
    let seconds: Double
    let held: Bool
    let editing: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onOpen: () -> Void

    @State private var pressing = false

    var body: some View {
        Group {
            if editing {
                // A plain Button while editing, a raw drag gesture while playing. Trying to serve
                // both from one gesture meant a pad that sometimes sounded on the way to being
                // opened.
                Button(action: onOpen) { face }.buttonStyle(.plain)
            } else {
                face.gesture(playGesture)
            }
        }
        .animation(.easeOut(duration: 0.08), value: held)
    }

    private var playGesture: some Gesture {
        // minimumDistance 0 makes the drag fire the instant the finger lands, which is the only
        // way to get a press event out of SwiftUI — a Button reports on release, a beat late.
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing, sample != nil else { return }
                pressing = true
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                onPress()
            }
            .onEnded { _ in
                guard pressing else { return }
                pressing = false
                onRelease()
            }
    }

    private var face: some View {
        VStack(spacing: 3) {
            if let sample {
                Text(sample.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(String(format: "%.1fs", seconds))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "plus")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(background)
        .overlay(border)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .scaleEffect(held ? 0.95 : 1)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(held ? JamControls.accent.opacity(0.45)
                       : Color.white.opacity(sample == nil ? 0.04 : 0.1))
    }

    @ViewBuilder
    private var border: some View {
        if editing {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(JamControls.accent,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else if sample != nil {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
    }
}

// MARK: - filling a pad

/// What edit mode opens. A flat list for now: the library has no folders and no trim, so there is
/// nothing here a full-screen browser would buy.
private struct SamplePicker: View {
    @ObservedObject var library: SampleLibrary
    @ObservedObject var pads: PadEngine
    let slot: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let loaded = library.sample(onPad: slot) {
                    Section {
                        TrimRow(library: library, sample: loaded, slot: slot)
                            .id("\(loaded.id)-\(slot)")
                        HoldToHear(pads: pads, slot: slot)
                        JamControls.GainSlider(decibels: Binding(
                            get: { library.pad(slot).decibels },
                            set: { library.setGain($0, onPad: slot) }))
                        ReleaseRow(library: library, slot: slot)
                        Button("clear pad \(slot + 1)", role: .destructive) {
                            library.assign(nil, toPad: slot)
                            dismiss()
                        }
                    } header: {
                        Text(loaded.name)
                    } footer: {
                        Text("these belong to the pad, not the sample — put the same loop on two pads and each keeps its own slice, level and release.")
                    }
                }
                Section {
                    if library.samples.isEmpty {
                        Text("nothing saved yet — hold the share button on a take")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(library.samples) { sample in
                            Button {
                                library.assign(sample, toPad: slot)
                                dismiss()
                            } label: {
                                SampleRow(sample: sample,
                                          onPad: library.pad(slot).sampleID == sample.id)
                            }
                        }
                        .onDelete { offsets in
                            for sample in offsets.map({ library.samples[$0] }) {
                                library.delete(sample)
                            }
                        }
                    }
                } header: {
                    Text("saved samples")
                } footer: {
                    Text("swipe to delete. deleting also clears any pad holding it.")
                }
            }
            .navigationTitle("pad \(slot + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }
}

/// The window this pad plays, over a waveform of the whole sample.
private struct TrimRow: View {
    @ObservedObject var library: SampleLibrary
    let sample: Sample
    let slot: Int

    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var seeded = false

    private var duration: Double { max(sample.seconds, 0.01) }
    private var trimmed: Bool { start > 0.001 || end < duration - 0.001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.2f – %.2f s", start, end))
                    .font(.caption.monospacedDigit())
                Text(String(format: "(%.2f s)", max(0, end - start)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if trimmed {
                    Button("whole sample") {
                        start = 0
                        end = duration
                        commit()
                    }
                    .font(.caption2)
                }
            }
            TrimStrip(url: sample.url, duration: duration, start: $start, end: $end,
                      onCommit: commit)
        }
        .onAppear {
            guard !seeded else { return }
            let window = library.pad(slot).windowOrWhole(of: duration)
            end = min(window.upperBound, duration)
            start = min(max(window.lowerBound, 0), max(0, end - TrimStrip.minimum))
            seeded = true
        }
    }

    private func commit() {
        library.setWindow(start...end, onPad: slot)
    }
}

/// Audition without leaving the sheet. The knob is only dialable if you can hear what it does,
/// and the drawer is behind this — the engine is still running, and this slot's voice already
/// carries whatever the slider last wrote.
private struct HoldToHear: View {
    @ObservedObject var pads: PadEngine
    let slot: Int

    @State private var pressing = false

    var body: some View {
        HStack {
            Image(systemName: pads.held.contains(slot) ? "speaker.wave.2.fill" : "hand.tap")
            Text("hold to hear it").font(.subheadline)
            Spacer()
        }
        .foregroundStyle(pads.held.contains(slot) ? Color.black : Color.primary)
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(pads.held.contains(slot) ? JamControls.accent : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    pads.press(slot)
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    pads.release(slot)
                }
        )
        // A List row swallows a drag as a scroll unless the row says otherwise.
        .listRowSeparator(.hidden)
    }
}

/// The one knob this cut of the pads exposes. A slider whose top stop is ring-out rather than a
/// mode switch beside a time: it is one gesture, and the useful settings are a continuum from a
/// hard choke up to not gating at all.
private struct ReleaseRow: View {
    @ObservedObject var library: SampleLibrary
    let slot: Int

    private var binding: Binding<Double> {
        Binding(get: { library.pad(slot).releaseSetting.position },
                set: { library.setRelease(PadRelease(position: $0), onPad: slot) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("release").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(library.pad(slot).releaseSetting.label)
                    .font(.caption.monospacedDigit())
            }
            // Stepped so the top of the travel is reachable exactly — a continuous slider makes
            // ring-out a value you can only approach.
            Slider(value: binding, in: 0...1, step: 0.025).tint(JamControls.accent)
            HStack {
                Text("choke").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("ring out").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SampleRow: View {
    let sample: Sample
    let onPad: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.name).font(.subheadline).foregroundStyle(.white)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if onPad {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(JamControls.accent)
            }
        }
    }

    private var detail: String {
        let source = TakeSession.Source(rawValue: sample.source)?.label ?? sample.source
        var parts = [String(format: "%.1fs", sample.seconds), source]
        if !sample.prompt.isEmpty { parts.append(sample.prompt) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - saving a take

/// The long-press on the share button. Names the sample and picks the pad it lands on, because a
/// sample saved to a library you cannot browse from the jam tab would be a sample you lost.
struct SaveToPadSheet: View {
    @ObservedObject var library: SampleLibrary
    let take: TakeSession.Take
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var slot = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("name") {
                    TextField("what is it", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("pad", selection: $slot) {
                        Text("library only").tag(-1)
                        ForEach(0..<SampleLibrary.padCount, id: \.self) { i in
                            Text(label(for: i)).tag(i)
                        }
                    }
                } header: {
                    Text("goes on")
                } footer: {
                    Text(String(format: "%.1fs · %@", SA3AudioFile.duration(take.url),
                                take.source.label))
                }
            }
            .navigationTitle("save to pads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("save", action: save) }
            }
            .onAppear {
                name = defaultName
                slot = library.firstEmptyPad ?? 0
            }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }

    private func label(for i: Int) -> String {
        if let existing = library.sample(onPad: i) { return "pad \(i + 1) — replaces \(existing.name)" }
        return "pad \(i + 1)"
    }

    /// The prompt if there was one, so a bank of generated hits is readable at a glance; the
    /// source otherwise, which is what a beatbox gets.
    private var defaultName: String {
        let prompt = take.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return take.source.label }
        return String(prompt.prefix(24))
    }

    private func save() {
        guard let sample = library.save(take.url, name: name, source: take.source,
                                        prompt: take.prompt, seed: take.seed) else {
            dismiss()
            return
        }
        if slot >= 0 { library.assign(sample, toPad: slot) }
        onSaved()
        dismiss()
    }
}

/// `sheet(item:)` wants an Identifiable. A wrapper rather than a retroactive conformance on Int,
/// which would be a conformance the whole module has to live with for the sake of one sheet.
private struct PadSlot: Identifiable { let id: Int }
