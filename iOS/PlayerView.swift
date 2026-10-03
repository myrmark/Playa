import AVFoundation
import MediaPlayer
import PlayaCore
import SwiftUI
import UIKit

/// What the player was opened with: the list the channel came from, so the next and
/// previous buttons can move through it.
struct PlayerSession: Identifiable {
    let id = UUID()
    /// For episodes: the show they belong to, so it can be recorded as recently watched.
    var showKey: String?
    let channels: [Channel]
    let index: Int
}

struct PlayerView: View {
    let session: PlayerSession

    @EnvironmentObject private var player: MPVPlayer
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var resume: ResumeStore
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var index = 0
    @State private var showsControls = true
    @State private var hideToken = 0
    @State private var watchTask: Task<Void, Never>?
    /// Slider value while the seek bar is being dragged.
    @State private var scrubPosition: Double?
    /// What a vertical swipe along a screen edge is adjusting, and the level it started from.
    @State private var edgeSwipe: (kind: EdgeAdjustment, start: Double)?
    @State private var edgeLevel: (kind: EdgeAdjustment, value: Double)?
    @State private var edgeToken = 0
    @State private var originalBrightness: CGFloat?
    @StateObject private var volume = SystemVolume()
    @AppStorage(PlayerView.backgroundSoundKey) private var playsInBackground = true
    @State private var isInBackground = false
    /// Closes a stream left paused in the background, so it doesn't hold the subscription's one stream.
    @State private var pausedCloseTask: Task<Void, Never>?

    static let backgroundSoundKey = "backgroundSound"

    private var channel: Channel { session.channels[index] }
    private var isLive: Bool { channel.kind == .live }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(layer: player.videoLayer)
                .ignoresSafeArea()
            // The video view doesn't take touches itself; this layer toggles the controls, and
            // swipes up and down along the right edge set the volume, along the left the brightness.
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showsControls { withAnimation { showsControls = false } } else { revealControls() }
                    }
                    .gesture(edgeGesture(in: geometry.size))
            }
            .ignoresSafeArea()
            // Present in the view tree, the volume view keeps the system's own volume display away.
            VolumeHost(view: volume.view)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)

            if let error = player.errorMessage {
                VStack(spacing: 12) {
                    Text(error)
                        .multilineTextAlignment(.center)
                    if player.canRetry {
                        Button("Reconnect") { player.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding()
            } else if player.isReconnecting {
                ProgressView("Reconnecting…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if player.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if showsControls || player.isPaused {
                controls
                    .transition(.opacity)
            }

            if let edgeLevel {
                EdgeLevelView(kind: edgeLevel.kind, value: edgeLevel.value)
                    // At the top, clear of the picture's centre.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .onAppear {
            index = session.index
            start()
            NowPlaying.attach(player)
            updateNowPlaying()
        }
        .onDisappear(perform: close)
        // A suspended app must not keep a stream open: on a single-stream subscription it would
        // collide with whatever is watched next on another device.
        // Unless the sound is to carry on, and is actually playing, so it can't be forgotten.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                guard playsInBackground, !player.isPaused, player.errorMessage == nil else {
                    dismiss()
                    return
                }
                isInBackground = true
                player.setVideoEnabled(false)
            case .active where isInBackground:
                isInBackground = false
                pausedCloseTask?.cancel()
                player.setVideoEnabled(true)
            default:
                break
            }
        }
        .onChange(of: player.isPaused) { _, isPaused in
            pausedCloseTask?.cancel()
            guard isInBackground, isPaused else { return }
            pausedCloseTask = Task {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled, isInBackground, player.isPaused { dismiss() }
            }
        }
        .onChange(of: player.errorMessage) { _, message in
            if isInBackground, message != nil { dismiss() }
        }
        .onChange(of: index) { _, _ in updateNowPlaying() }
        .onChange(of: epg.version) { _, _ in updateNowPlaying() }
        .onChange(of: player.position) { _, position in
            if Int(position) % 10 == 0, position > 0 { savePosition(isFinal: false) }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding(8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isLive, let now = epg.guide.nowAndNext(channelID: channel.tvgID, at: Date()).now {
                        Text("\(now.title)  ·  \(now.start.formatted(date: .omitted, time: .shortened))–\(now.stop.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trackMenu
                Button {
                    store.toggleFavourite(channel)
                } label: {
                    Image(systemName: store.favourites.contains(channel.key) ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(store.favourites.contains(channel.key) ? .yellow : .white)
                        .padding(8)
                }
            }
            .padding()

            Spacer()
            HStack(spacing: 44) {
                Button {
                    if isLive { zap(-1) } else { seek(by: -15) }
                } label: {
                    Image(systemName: isLive ? "backward.end.fill" : "gobackward.15")
                        .font(.title)
                }
                .disabled(isLive && index == 0)
                Button {
                    player.togglePause()
                    revealControls()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 46))
                        .frame(width: 60)
                }
                Button {
                    if isLive { zap(1) } else { seek(by: 15) }
                } label: {
                    Image(systemName: isLive ? "forward.end.fill" : "goforward.15")
                        .font(.title)
                }
                .disabled(isLive && index == session.channels.count - 1)
            }
            Spacer()

            bottomBar
                .padding()
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isLive {
            let programmes = epg.guide.nowAndNext(channelID: channel.tvgID, at: Date())
            VStack(alignment: .leading, spacing: 4) {
                if let description = programmes.now?.description {
                    Text(description)
                        .font(.footnote)
                        .lineLimit(3)
                }
                if let next = programmes.next {
                    Text("Next: \(next.title)  ·  \(next.start.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if player.duration > 0 {
            HStack(spacing: 10) {
                Text(Self.timestamp(scrubPosition ?? player.position))
                Slider(
                    value: Binding(get: { scrubPosition ?? player.position }, set: { scrubPosition = $0 }),
                    in: 0...player.duration
                ) { isEditing in
                    if isEditing {
                        hideToken += 1
                    } else if let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                        revealControls()
                    }
                }
                Text(Self.timestamp(player.duration))
            }
            .font(.caption.monospacedDigit())
        }
    }

    /// Audio and subtitle choices, shown only when the stream offers any.
    @ViewBuilder
    private var trackMenu: some View {
        let audio = player.tracks.filter { $0.kind == .audio }
        let subtitles = player.tracks.filter { $0.kind == .subtitle }
        if audio.count > 1 || !subtitles.isEmpty {
            Menu {
                if audio.count > 1 {
                    Section("Audio") {
                        ForEach(audio) { track in
                            Button {
                                player.selectAudio(track)
                            } label: {
                                if track.isSelected { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                            }
                        }
                    }
                }
                if !subtitles.isEmpty {
                    Section("Subtitles") {
                        Button {
                            player.selectSubtitle(nil)
                        } label: {
                            if subtitles.contains(where: \.isSelected) { Text("Off") } else { Label("Off", systemImage: "checkmark") }
                        }
                        ForEach(subtitles) { track in
                            Button {
                                player.selectSubtitle(track)
                            } label: {
                                if track.isSelected { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.title3)
                    .padding(8)
            }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func start() {
        player.play(url: channel.url, startAt: resume.resumePosition(for: channel), isLive: isLive)
        revealControls()
        // Zapping past a channel shouldn't count as watching it.
        let started = channel
        watchTask?.cancel()
        watchTask = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, channel.url == started.url {
                store.noteWatched([started.key] + (session.showKey.map { [$0] } ?? []))
            }
        }
    }

    private func zap(_ offset: Int) {
        guard session.channels.indices.contains(index + offset) else { return }
        savePosition(isFinal: true)
        index += offset
        start()
    }

    private func seek(by seconds: Double) {
        guard player.duration > 0 else { return }
        player.seek(to: min(max(player.position + seconds, 0), player.duration - 1))
        revealControls()
    }

    /// Shows the controls and hides them again after a few seconds without a touch.
    private func revealControls() {
        hideToken += 1
        let token = hideToken
        withAnimation { showsControls = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if token == hideToken { withAnimation { showsControls = false } }
        }
    }

    private func savePosition(isFinal: Bool) {
        guard player.duration > 0 else { return }
        resume.record(channel, position: player.position, duration: player.duration, isFinal: isFinal)
    }

    /// A vertical drag that starts in the outer third of the screen. Sideways drags and the
    /// middle are left alone, so they don't fight with taps and the seek bar.
    private func edgeGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                if edgeSwipe == nil {
                    guard abs(drag.translation.height) > abs(drag.translation.width) else { return }
                    let x = drag.startLocation.x
                    if x > size.width * 2 / 3 {
                        edgeSwipe = (.volume, volume.level)
                    } else if x < size.width / 3 {
                        if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
                        edgeSwipe = (.brightness, Double(UIScreen.main.brightness))
                    } else {
                        return
                    }
                }
                guard let swipe = edgeSwipe else { return }
                // Three quarters of the screen's height covers the whole range.
                let value = min(max(swipe.start - drag.translation.height / (size.height * 0.75), 0), 1)
                switch swipe.kind {
                case .volume: volume.level = value
                case .brightness: UIScreen.main.brightness = value
                }
                edgeToken += 1
                withAnimation(.easeOut(duration: 0.1)) { edgeLevel = (swipe.kind, value) }
            }
            .onEnded { _ in
                edgeSwipe = nil
                let token = edgeToken
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if token == edgeToken { withAnimation { edgeLevel = nil } }
                }
            }
    }

    /// What the Lock Screen and Control Centre show while the sound plays on.
    private func updateNowPlaying() {
        var info: [String: Any] = [MPMediaItemPropertyTitle: channel.name]
        if isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            if let now = epg.guide.nowAndNext(channelID: channel.tvgID, at: Date()).now {
                info[MPMediaItemPropertyArtist] = now.title
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func close() {
        pausedCloseTask?.cancel()
        NowPlaying.detach()
        // Brightness set for watching is for watching only.
        if let originalBrightness { UIScreen.main.brightness = originalBrightness }
        watchTask?.cancel()
        savePosition(isFinal: true)
        player.stop()
    }
}

/// Play and pause from the Lock Screen, Control Centre and headphones.
@MainActor
enum NowPlaying {
    static func attach(_ player: MPVPlayer) {
        detach()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in player.setPaused(false); return .success }
        center.pauseCommand.addTarget { _ in player.setPaused(true); return .success }
        center.togglePlayPauseCommand.addTarget { _ in player.togglePause(); return .success }
    }

    static func detach() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            command.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

enum EdgeAdjustment {
    case volume, brightness
}

/// The level being set by an edge swipe.
private struct EdgeLevelView: View {
    let kind: EdgeAdjustment
    let value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .volume
                  ? (value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                  : "sun.max.fill")
                .frame(width: 26)
            ProgressView(value: value)
                .tint(.white)
                .frame(width: 140)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The device's own volume. Apps have no direct way to set it; the slider inside the system
/// volume view is the accepted route.
@MainActor
final class SystemVolume: ObservableObject {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))

    var level: Double {
        get { Double(AVAudioSession.sharedInstance().outputVolume) }
        set {
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.setValue(Float(newValue), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

private struct VolumeHost: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// Hosts the layer mpv renders into.
struct VideoSurface: UIViewRepresentable {
    let layer: CAMetalLayer

    func makeUIView(context: Context) -> VideoContainerView {
        VideoContainerView(videoLayer: layer)
    }

    func updateUIView(_ view: VideoContainerView, context: Context) {}
}

final class VideoContainerView: UIView {
    private let videoLayer: CAMetalLayer

    init(videoLayer: CAMetalLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        // Without this the layer animates to its new size when the device rotates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}
