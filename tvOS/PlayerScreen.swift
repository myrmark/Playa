import PlayaCore
import SwiftUI
import UIKit

/// What the player was opened with: the list the channel came from, so up/down can zap through it.
struct PlayerSession: Identifiable {
    let id = UUID()
    /// For episodes: the show they belong to, so it can be recorded as recently watched.
    var showKey: String?
    let channels: [Channel]
    let index: Int
}

struct PlayerScreen: View {
    let session: PlayerSession

    @EnvironmentObject private var player: MPVPlayer
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var resume: ResumeStore
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var index = 0
    @State private var showsInfo = true
    @State private var infoToken = 0
    @State private var showsTracks = false
    /// The channel list drawn over the picture, so the guide can be read without leaving playback.
    @State private var showsPanel = false
    @FocusState private var panelFocus: Int?
    @AppStorage(PlayerScreen.panelOpacityKey) private var panelOpacity = PlayerScreen.defaultPanelOpacity
    @State private var watchTask: Task<Void, Never>?

    /// How solid the channel panel is, in percent; lower lets more of the picture through.
    static let panelOpacityKey = "panelOpacity"
    static let defaultPanelOpacity = 70

    private var channel: Channel { session.channels[index] }
    private var isLive: Bool { channel.kind == .live }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(layer: player.videoLayer)
                .ignoresSafeArea()

            if let error = player.errorMessage {
                VStack(spacing: 16) {
                    Text(error)
                    if player.canRetry {
                        Text("Press Play/Pause to reconnect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            } else if player.isBuffering {
                ProgressView()
            }

            if showsPanel {
                channelPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if showsInfo || player.isPaused {
                infoBar
                    .transition(.opacity)
            }
        }
        // While the panel is open its rows take the remote; otherwise the picture does.
        .focusable(!showsPanel)
        // Pressing select brings up the channel list over the picture, which keeps playing.
        .onTapGesture {
            withAnimation { showsPanel = true }
        }
        .sheet(isPresented: $showsTracks) { trackList }
        .onPlayPauseCommand {
            if player.canRetry { player.retry() } else { player.togglePause() }
            flashInfo()
        }
        .onMoveCommand { direction in
            switch direction {
            // Swiping down brings up the channel list, as select does.
            case .down: withAnimation { showsPanel = true }
            case .left where isLive: zap(-1)
            case .right where isLive: zap(1)
            case .left where !isLive: seek(by: -15)
            case .right where !isLive: seek(by: 15)
            default: flashInfo()
            }
        }
        .onAppear {
            index = session.index
            start()
        }
        .onDisappear(perform: close)
        // A suspended app must not keep a stream open: on a single-stream subscription it would
        // collide with whatever is watched next on another device.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dismiss() }
        }
        .onChange(of: player.position) { _, position in
            if Int(position) % 10 == 0, position > 0 { savePosition(isFinal: false) }
        }
    }

    /// The channels of the list being watched, with what each is showing, over the left of the
    /// picture. Choosing one switches to it; the back button just closes the panel.
    private var channelPanel: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    if hasTrackChoices {
                        Button {
                            showsPanel = false
                            showsTracks = true
                        } label: {
                            Label("Audio and subtitles", systemImage: "captions.bubble")
                        }
                    }
                    ForEach(Array(session.channels.enumerated()), id: \.element.id) { position, entry in
                        Button {
                            if position != index {
                                savePosition(isFinal: true)
                                index = position
                                start()
                            }
                            withAnimation { showsPanel = false }
                        } label: {
                            PanelRow(channel: entry, isPlaying: position == index)
                        }
                        .focused($panelFocus, equals: entry.id)
                        .id(entry.id)
                    }
                }
                .onAppear {
                    proxy.scrollTo(channel.id, anchor: .center)
                    // The row has to exist before it can take focus.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { panelFocus = channel.id }
                }
            }
            .frame(width: 860)
            .padding(.vertical, 40)
            // Clear of the screen edge, which TVs often crop.
            .padding(.leading, 50)
            .background(Color.black.opacity(Double(panelOpacity) / 100))
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .onExitCommand {
            withAnimation { showsPanel = false }
        }
    }

    private var hasTrackChoices: Bool {
        player.tracks.filter { $0.kind == .audio }.count > 1 || player.tracks.contains { $0.kind == .subtitle }
    }

    private var trackList: some View {
        let audio = player.tracks.filter { $0.kind == .audio }
        let subtitles = player.tracks.filter { $0.kind == .subtitle }
        return List {
            if audio.count > 1 {
                Section("Audio") {
                    ForEach(audio) { track in
                        trackButton(track.label, isSelected: track.isSelected) { player.selectAudio(track) }
                    }
                }
            }
            if !subtitles.isEmpty {
                Section("Subtitles") {
                    trackButton("Off", isSelected: !subtitles.contains(where: \.isSelected)) { player.selectSubtitle(nil) }
                    ForEach(subtitles) { track in
                        trackButton(track.label, isSelected: track.isSelected) { player.selectSubtitle(track) }
                    }
                }
            }
        }
    }

    private func trackButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showsTracks = false
        } label: {
            HStack {
                Text(title)
                Spacer()
                if isSelected { Image(systemName: "checkmark") }
            }
        }
    }

    private var infoBar: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text(channel.name)
                    .font(.title3)
                    .lineLimit(1)
                if isLive {
                    let programmes = epg.guide.nowAndNext(channelID: channel.tvgID, at: Date())
                    if let now = programmes.now {
                        Text("Now: \(now.title)  ·  \(now.start.formatted(date: .omitted, time: .shortened))–\(now.stop.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        if let description = now.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    if let next = programmes.next {
                        Text("Next: \(next.title)  ·  \(next.start.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                } else if player.duration > 0 {
                    ProgressView(value: min(player.position, player.duration), total: player.duration)
                    Text("\(Self.timestamp(player.position)) / \(Self.timestamp(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text((hasTrackChoices ? "Swipe down for channels, audio and subtitles" : "Swipe down for channels")
                    + (isLive ? "  ·  left and right change channel" : ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(60)
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func start() {
        player.play(url: channel.url, startAt: resume.resumePosition(for: channel), isLive: isLive)
        flashInfo()
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
        index += offset
        start()
    }

    private func seek(by seconds: Double) {
        guard player.duration > 0 else { return }
        player.seek(to: min(max(player.position + seconds, 0), player.duration - 1))
        flashInfo()
    }

    /// Shows the info bar for a few seconds.
    private func flashInfo() {
        infoToken += 1
        let token = infoToken
        withAnimation { showsInfo = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if token == infoToken { withAnimation { showsInfo = false } }
        }
    }

    private func savePosition(isFinal: Bool) {
        guard player.duration > 0 else { return }
        resume.record(channel, position: player.position, duration: player.duration, isFinal: isFinal)
    }

    private func close() {
        watchTask?.cancel()
        savePosition(isFinal: true)
        player.stop()
    }
}

/// A row of the in-player channel list: the channel and what it is showing now and next.
private struct PanelRow: View {
    let channel: Channel
    let isPlaying: Bool

    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var resume: ResumeStore

    var body: some View {
        let programmes = epg.guide.nowAndNext(channelID: channel.tvgID, at: Date())
        HStack(spacing: 16) {
            Image(systemName: "play.fill")
                .font(.caption)
                .opacity(isPlaying ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .lineLimit(1)
                if let now = programmes.now {
                    Text("\(now.title)  ·  until \(now.stop.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let next = programmes.next {
                    Text("Next: \(next.title)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if channel.kind != .live, let label = resume.label(for: channel) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Keeps the text readable when the panel is mostly transparent.
        .shadow(color: .black.opacity(0.8), radius: 4)
    }
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
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
