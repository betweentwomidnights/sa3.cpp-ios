import SwiftUI

/// Shaping the current take before anything else touches it.
///
/// Crop and gain today. The layout is the shape it will keep — the strip picks the region, the
/// controls below act on it, and anything added later (a reverb, a filter, an automation lane)
/// is another control in that stack rather than another screen.
///
/// Nothing here is destructive until `done`. The edit is auditioned live through `PadEngine` and
/// only rendered to a file on the way out, so backing out costs nothing and `done` produces a
/// take that is exactly what you heard.
struct TakeEditor: View {
    let take: TakeSession.Take
    @ObservedObject var pads: PadEngine
    let onDone: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var decibels: Double = 0
    @State private var duration: Double = 0
    @State private var rendering = false

    private var window: ClosedRange<Double>? {
        guard duration > 0, start > 0.001 || end < duration - 0.001 else { return nil }
        return start...end
    }
    private var changed: Bool { window != nil || abs(decibels) > 0.05 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if duration > 0 {
                        TrimStrip(url: take.url, duration: duration,
                                  start: $start, end: $end, height: 128,
                                  onCommit: restartAudition)
                    }
                    lengths
                    audition
                    JamControls.GainSlider(decibels: $decibels, onCommit: restartAudition)
                    Text("crop and level for now. reverb, filter and their automation belong in this stack, which is why it is a stack.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("edit take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { pads.stopAudition(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done", action: render).disabled(!changed || rendering)
                }
            }
            .onAppear {
                duration = SA3AudioFile.duration(take.url)
                end = duration
            }
            .onDisappear { pads.stopAudition() }
        }
        .preferredColorScheme(.dark)
        .tint(JamControls.accent)
    }

    private var lengths: some View {
        HStack {
            Text(String(format: "%.2f – %.2f s", start, end))
                .font(.caption.monospacedDigit())
            Text(String(format: "(%.2f s of %.2f)", max(0, end - start), duration))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if window != nil {
                Button("whole take") {
                    start = 0
                    end = duration
                    restartAudition()
                }
                .font(.caption2)
            }
        }
    }

    /// Plays the selection at the chosen level, not the file — the whole point is hearing the
    /// edit rather than the thing it was made from.
    private var audition: some View {
        Button {
            if pads.auditioning { pads.stopAudition() } else { startAudition() }
        } label: {
            Label(pads.auditioning ? "stop" : "hear the selection",
                  systemImage: pads.auditioning ? "stop.fill" : "play.fill")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func startAudition() {
        pads.audition(take.url, window: window, gainDB: decibels)
    }

    /// Moving a handle or the fader while it is sounding should change what you hear, not stop it.
    private func restartAudition() {
        guard pads.auditioning else { return }
        startAudition()
    }

    private func render() {
        rendering = true
        pads.stopAudition()
        guard let url = SA3AudioFile.render(take.url, window: window, gainDB: decibels) else {
            rendering = false
            return
        }
        onDone(url)
        dismiss()
    }
}
