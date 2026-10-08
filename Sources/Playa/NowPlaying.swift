import Foundation
import MediaPlayer

/// Tells macOS what Playa is playing, so the media keys, headphone buttons and Control Centre
/// act on Playa rather than on whichever app played something last.
///
/// The buttons only act on a stream that is already open: headphones send "play" by themselves
/// when they are put back in, and that must never open a stream nobody asked for.
@MainActor
final class NowPlaying {
    var togglePause: () -> Void = {}

    private var isOpen = false
    private var isPaused = false

    init() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.act { _ in true } ?? .commandFailed }
        center.playCommand.addTarget { [weak self] _ in self?.act { $0.isPaused } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.act { !$0.isPaused } ?? .commandFailed }
        // Next and previous are left alone: a double press on a headphone must not change channel.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// - Parameters:
    ///   - title: the channel or film; nil when no stream is open.
    ///   - detail: the programme on now, when the guide says.
    func update(title: String?, detail: String?, isPaused: Bool, isLive: Bool, position: Double, duration: Double) {
        let center = MPNowPlayingInfoCenter.default()
        guard let title else {
            isOpen = false
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        isOpen = true
        self.isPaused = isPaused
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        if let detail { info[MPMediaItemPropertyArtist] = detail }
        if !isLive, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        center.nowPlayingInfo = info
        center.playbackState = isPaused ? .paused : .playing
    }

    private nonisolated func act(when wanted: @escaping @MainActor (NowPlaying) -> Bool) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isOpen, wanted(self) else { return }
                self.togglePause()
            }
        }
        return .success
    }
}
