import AVFoundation
import SwiftUI

/// Whether anything other than the phone's own speaker is listening.
///
/// The mic overdub needs this because the bleed is physical rather than architectural: add plays
/// the take out loud while the mic is open, so on the loudspeaker the performance gets printed over
/// a recording of itself. Nothing in software fixes that — the only real answers are headphones or
/// a take printed twice at different levels.
///
/// Watching the route rather than warning unconditionally is what makes the warning worth reading.
/// It appears when you are actually on the speaker and clears the moment the buds go in, so it is
/// information rather than the boilerplate you learn to tap past.
@MainActor
final class AudioRoute: ObservableObject {

    @Published private(set) var headphonesConnected = false

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Anything that is not the loudspeaker or the earpiece counts. Wired, bluetooth, USB, AirPlay
    /// and CarPlay all put the output somewhere the microphone cannot hear it, which is the only
    /// property being asked about here.
    private func refresh() {
        headphonesConnected = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    @objc private nonisolated func routeChanged(_ note: Notification) {
        Task { @MainActor in self.refresh() }
    }
}
