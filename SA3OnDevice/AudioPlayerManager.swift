import AVFoundation
import SwiftUI

extension Notification.Name {
    /// Carries playhead position to the waveform. A notification rather than a binding because the
    /// waveform is a UIKit view: it wants a 10 Hz push it can apply directly to its highlight,
    /// not a SwiftUI state write that would re-evaluate the whole tab ten times a second.
    static let waveformProgress = Notification.Name("sa3.waveformProgress")
}

/// Playback for the current take. One take at a time, so one player.
@MainActor
final class AudioPlayerManager: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?
    let id = "current-take"

    /// Point the player at a take. Any existing player is dropped rather than reused: a new take
    /// is a different file, and reusing the player would keep playing the old one.
    func setURL(_ url: URL?) {
        guard url != self.url else { return }
        stopAndRelease()
        self.url = url
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let url else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
        }
        guard player?.play() == true else { return }
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        stopTicking()
        postProgress()
    }

    func seek(to time: TimeInterval) {
        if player == nil, let url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
        }
        player?.currentTime = time
        postProgress()
    }

    func stopAndRelease() {
        player?.stop()
        player = nil
        isPlaying = false
        stopTicking()
    }

    private func startTicking() {
        stopTicking()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postProgress() }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func postProgress() {
        guard let player else { return }
        let t = player.currentTime, d = player.duration
        guard t.isFinite, d.isFinite, d > 0 else { return }
        NotificationCenter.default.post(name: .waveformProgress, object: nil,
                                        userInfo: ["id": id, "currentTime": t, "duration": d])
    }
}

extension AudioPlayerManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTicking()
            player.currentTime = 0
            NotificationCenter.default.post(name: .waveformProgress, object: nil,
                                            userInfo: ["id": self.id, "currentTime": 0.0,
                                                       "duration": player.duration])
        }
    }
}
