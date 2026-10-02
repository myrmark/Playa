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
    @State private var watchTask: Task<Void, Never>?

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

            if showsInfo || player.isPaused {
                infoBar
                    .transition(.opacity)
            }
        }
        .focusable()
        // Pressing select opens the audio and subtitle choices when the stream has any.
        .onTapGesture {
            if hasTrackChoices { showsTracks = true } else { flashInfo() }
        }
        .sheet(isPresented: $showsTracks) { trackList }
        .onPlayPauseCommand {
            if player.canRetry { player.retry() } else { player.togglePause() }
            flashInfo()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up where isLive: zap(-1)
            case .down where isLive: zap(1)
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
                if hasTrackChoices {
                    Text("Press select for audio and subtitles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
