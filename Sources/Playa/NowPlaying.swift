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
    /// Moves to the channel above (-1) or below (+1).
    var zap: (Int) -> Void = { _ in }

    private var isOpen = false
    private var isPaused = false
    private var isLive = true

    init() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.act { _ in true } ?? .commandFailed }
        center.playCommand.addTarget { [weak self] _ in self?.act { $0.isPaused } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.act { !$0.isPaused } ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.move(1) ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.move(-1) ?? .commandFailed }
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
        self.isLive = isLive
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

    private nonisolated func move(_ offset: Int) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isOpen, self.isLive else { return }
                self.zap(offset)
            }
        }
        return .success
    }
}
