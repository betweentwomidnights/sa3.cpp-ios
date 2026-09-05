import AVFoundation
import FDWaveformView
import SwiftUI
import UIKit

/// The take's waveform, with a tap-to-seek playhead.
///
/// FDWaveformView renders from the file rather than from samples we hold, so it wants the URL and
/// nothing else. Progress arrives over `.waveformProgress` and is applied straight to
/// `highlightedSamples` — pushing it through SwiftUI state instead would re-render the tab at the
/// player's tick rate for a highlight the UIKit view can move itself.
struct WaveformView: UIViewRepresentable {
    let id: String
    let url: URL?
    var onSeek: (TimeInterval) -> Void = { _ in }
    /// A fixed selection in seconds. Setting it turns the view from a playhead into a window: the
    /// highlight shows the range instead of progress, tapping no longer seeks, and the
    /// `.waveformProgress` ticks are ignored so the player cannot argue with the handles.
    var window: ClosedRange<Double>? = nil

    func makeUIView(context: Context) -> FDWaveformView {
        let view = FDWaveformView()
        view.delegate = context.coordinator
        context.coordinator.view = view
        style(view)
        if let url {
            view.audioURL = url
            context.coordinator.lastURL = url
        }
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: FDWaveformView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.window = window
        context.coordinator.applyWindow()
        guard let url, url != context.coordinator.lastURL else { return }
        // Clearing first matters: FDWaveformView keeps the old render until the new asset finishes
        // loading, so an undo would show the take you just left for as long as the read takes.
        view.audioURL = nil
        view.audioURL = url
        view.highlightedSamples = 0..<0
        context.coordinator.lastURL = url
        context.coordinator.duration = Self.duration(url)
        style(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self, id: id) }

    private func style(_ view: FDWaveformView) {
        view.wavesColor = UIColor(white: 1, alpha: 0.28)
        view.progressColor = .systemTeal
        view.backgroundColor = .clear
        // Scrubbing and stretching are FDWaveformView's own gestures; the tap recogniser above is
        // the whole interaction here, and leaving them on made the waveform fight the scroll view.
        view.doesAllowScrubbing = false
        view.doesAllowStretch = false
        view.doesAllowScroll = false
    }

    private static func duration(_ url: URL) -> TimeInterval? {
        let d = SA3AudioFile.duration(url)
        return d > 0 ? d : nil
    }

    final class Coordinator: NSObject, FDWaveformViewDelegate {
        var parent: WaveformView
        weak var view: FDWaveformView?
        var lastURL: URL?
        var duration: TimeInterval?
        var window: ClosedRange<Double>?
        let id: String

        init(_ parent: WaveformView, id: String) {
            self.parent = parent
            self.id = id
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(progress(_:)), name: .waveformProgress, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Paints the window onto the same `highlightedSamples` the playhead uses. FDWaveformView
        /// only has the one highlight, and a selection is what it reads as here.
        func applyWindow() {
            guard let window, let view, let duration, duration > 0 else { return }
            let total = view.totalSamples
            guard total > 0 else { return }        // retried from waveformViewDidLoad
            func frame(_ t: Double) -> Int { Int(Double(total) * min(max(t / duration, 0), 1)) }
            let lower = frame(window.lowerBound)
            view.highlightedSamples = lower..<max(lower, frame(window.upperBound))
        }

        @objc func progress(_ note: Notification) {
            guard window == nil,
                  let info = note.userInfo,
                  info["id"] as? String == id,
                  let t = info["currentTime"] as? TimeInterval,
                  let d = info["duration"] as? TimeInterval,
                  d > 0, let view else { return }
            let total = view.totalSamples
            guard total > 0 else { return }
            let n = min(total, max(0, Int(Double(total) * (t / d))))
            view.highlightedSamples = 0..<n
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard window == nil else { return }
            guard let view, view.bounds.width > 0, let duration, duration > 0 else { return }
            let fraction = min(max(gesture.location(in: view).x / view.bounds.width, 0), 1)
            view.highlightedSamples = 0..<Int(Double(view.totalSamples) * fraction)
            parent.onSeek(duration * Double(fraction))
        }

        func waveformViewDidLoad(_ view: FDWaveformView) {
            self.view = view
            if let url = view.audioURL { duration = WaveformView.duration(url) }
            // totalSamples is 0 until the render finishes, so the window set during layout had
            // nothing to scale against. This is where it lands.
            applyWindow()
        }
    }
}

/// A waveform with two drag handles, for picking the slice of a file that matters.
///
/// Shared by the pad editor and the take editor, which want the same gesture over very different
/// lengths of audio — a 200 ms snare out of a bar, or the last four seconds off a take.
///
/// The handles move on every frame of the drag but `onCommit` only fires when the finger lifts.
/// Whatever consumes the window is re-slicing a buffer or rewriting a file, and neither is worth
/// doing sixty times a second for one gesture.
struct TrimStrip: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var height: CGFloat = 78
    var onCommit: () -> Void = {}

    /// Short enough to isolate a single transient, long enough that a handle cannot be dragged
    /// past its partner into an empty window.
    static let minimum = 0.02

    private var space: String { "trim-\(url.lastPathComponent)" }
    private var span: Double { max(duration, 0.01) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                WaveformView(id: "trim-\(url.lastPathComponent)", url: url,
                             window: min(start, end)...max(start, end))
                // Everything outside the window is dimmed rather than hidden: the shape of what
                // you are cutting away is how you find the part you actually want.
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: position(start, width))
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(0, width - position(end, width)))
                    .offset(x: position(end, width))
                handle(at: start, isStart: true, width: width)
                handle(at: end, isStart: false, width: width)
            }
            .coordinateSpace(name: space)
        }
        .frame(height: height)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func position(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(seconds / span, 0), 1)) * width
    }

    private func handle(at seconds: Double, isStart: Bool, width: CGFloat) -> some View {
        ZStack {
            // A 32pt transparent column so the grab area is a finger wide while the line stays
            // thin enough to place against a transient.
            Color.clear
            Capsule().fill(JamControls.accent).frame(width: 3)
            Circle().fill(JamControls.accent).frame(width: 13, height: 13)
                .frame(maxHeight: .infinity, alignment: isStart ? .top : .bottom)
        }
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .offset(x: position(seconds, width) - 16)
        // highPriority so an enclosing List or ScrollView does not read the drag as a scroll.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    let t = min(max(Double(value.location.x / max(width, 1)) * span, 0), span)
                    if isStart {
                        start = min(t, end - Self.minimum)
                    } else {
                        end = max(t, start + Self.minimum)
                    }
                }
                .onEnded { _ in onCommit() }
        )
    }
}
