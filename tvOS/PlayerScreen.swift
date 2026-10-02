import PlayaCore
import SwiftUI
import AVKit
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
    /// The info bar with its row of options, opened by swiping up.
    @State private var showsOptions = false
    @FocusState private var optionFocus: Int?
    @AppStorage(PlayerScreen.panelOpacityKey) private var panelOpacity = PlayerScreen.defaultPanelOpacity
    @State private var watchTask: Task<Void, Never>?
    /// Playback details in the corner, for telling a slow stream from a slow player.
    @State private var showsHealth = false
    @StateObject private var screen = ScreenRate()

    /// How solid the channel panel is, in percent; lower lets more of the picture through.
    /// Off unless chosen: on some TVs the switch of mode also changes how colours look.
    static let matchRateKey = "matchRefreshRate"
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

            if showsHealth {
                HealthOverlay()
            }

            if showsPanel {
                channelPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if showsOptions || showsInfo || player.isPaused {
                infoBar
                    .transition(.opacity)
            }
        }
        // While a panel is open its buttons take the remote; otherwise the picture does.
        .focusable(!showsPanel && !showsOptions)
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
            // With a panel open, swipes move between its buttons and mustn't also reach the stream.
            guard !showsPanel, !showsOptions else { return }
            switch direction {
            // Swiping down brings up the channel list, as select does.
            case .down: withAnimation { showsPanel = true }
            case .left where isLive: zap(-1)
            case .right where isLive: zap(1)
            case .left where !isLive: seek(by: -15)
            case .right where !isLive: seek(by: 15)
            // Swiping up brings up the info bar with the options for this stream.
            case .up:
                withAnimation { showsOptions = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { optionFocus = 0 }
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
        .onChange(of: player.videoFPS) { _, fps in matchScreen(to: fps) }
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
                if showsOptions {
                    options
                } else {
                    Text("Swipe down for channels  ·  up for options" + (isLive ? "  ·  left and right change channel" : ""))
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

    /// What can be changed about the stream that is playing. Back closes the row.
    private var options: some View {
        HStack(spacing: 24) {
            if hasTrackChoices {
                Button {
                    showsOptions = false
                    showsTracks = true
                } label: {
                    Label("Audio and subtitles", systemImage: "captions.bubble")
                }
                .focused($optionFocus, equals: 0)
            }
            Button {
                let all = MPVPlayer.Quality.allCases
                player.quality = all[((all.firstIndex(of: player.quality) ?? 0) + 1) % all.count]
            } label: {
                Label("Picture: \(player.quality.title)", systemImage: "sparkles.tv")
            }
            .focused($optionFocus, equals: hasTrackChoices ? 1 : 0)
            Button {
                showsHealth.toggle()
            } label: {
                Label(showsHealth ? "Hide playback details" : "Show playback details", systemImage: "waveform.path.ecg")
            }
            .focused($optionFocus, equals: 2)
        }
        .padding(.top, 10)
        .onExitCommand {
            withAnimation { showsOptions = false }
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

    private var displayManager: AVDisplayManager? {
        // The window gains this property only once AVKit is loaded, and nothing else here uses
        // AVKit, so name one of its classes to make sure it is.
        _ = AVPlayerViewController.self
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first,
              window.responds(to: #selector(getter: UIWindow.avDisplayManager))
        else { return nil }
        return window.avDisplayManager
    }

    /// Asks the TV to run at the stream's frame rate, so 50 fps channels aren't shown with the
    /// stutter of being fitted into 60 Hz. tvOS acts on it only when Match Frame Rate is on in
    /// its settings. Kept across channel changes, so the screen doesn't switch back and forth.
    private func matchScreen(to fps: Double) {
        guard fps > 0, UserDefaults.standard.bool(forKey: Self.matchRateKey) else { return }
        // The request names a dynamic range as well as a rate. Naming plain SDR makes an Apple TV
        // that runs in HDR drop out of it, and the TV then shows its SDR picture settings, so
        // describe the video as the range the screen is already in.
        let isHDR = UIScreen.main.potentialEDRHeadroom > 1
        let extensions: [CFString: Any]? = isHDR ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ] : nil
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: isHDR ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, width: 1920, height: 1080,
            extensions: extensions as CFDictionary?, formatDescriptionOut: &format)
        guard let format else { return }
        // Interlaced 25 and 30 fps streams are shown at twice their frame rate.
        let rate = fps < 31 && fps > 24.5 ? fps * 2 : fps
        // A screen already at that rate is left alone: asking would only risk a change of mode.
        guard screen.rate > 0, abs(screen.rate - rate) > 1 else { return }
        displayManager?.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(rate), formatDescription: format)
    }

    private func close() {
        displayManager?.preferredDisplayCriteria = nil
        watchTask?.cancel()
        savePosition(isFinal: true)
        player.stop()
    }
}

/// Live figures on the stream and the decoder, with a plain reading of what they mean.
private struct HealthOverlay: View {
    @EnvironmentObject private var player: MPVPlayer
    @State private var health = MPVPlayer.Health()
    @StateObject private var screen = ScreenRate()
    /// Dropped-frame counts from the last half minute, oldest first.
    @State private var drops: [Int] = []

    private var recentDrops: Int { (drops.last ?? 0) - (drops.first ?? 0) }

    private var verdict: String {
        if health.video.hasPrefix("?") { return "Waiting for the stream." }
        if health.bufferedSeconds < 1 || (health.needed > 0 && health.arriving < health.needed * 0.9 && health.bufferedSeconds < 3) {
            return "The stream is arriving too slowly: the network or the provider."
        }
        if recentDrops > 15 {
            return "Data arrives in time but frames are dropped: the player isn't keeping up."
        }
        return health.stalls > 0 ? "Fine now. Earlier stalls were waits for data." : "Playing normally."
    }

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(health.video)
                    Text("Decoding: \(health.decoder)  ·  picture: \(player.quality.title.lowercased())")
                    Text("Dropped frames: \(health.droppedFrames) (\(recentDrops) in the last 30 s)")
                    Text("  drawing: \(health.droppedDrawing)  ·  decoding: \(health.droppedFrames - health.droppedDrawing)")
                    Text("Screen: \(screen.rate, specifier: "%.0f") Hz")
                    Text("Buffered ahead: \(health.bufferedSeconds, specifier: "%.1f") s")
                    Text("Arriving: \(Self.rate(health.arriving))  ·  needed: \(Self.rate(health.needed))")
                    Text("Stalls: \(health.stalls)  ·  open for \(health.minutesOpen) min")
                    Text("Memory: \(health.memoryMB) MB")
                    Text(verdict)
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .font(.caption.monospacedDigit())
                .padding(24)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
            Spacer()
        }
        .padding(60)
        .task {
            while !Task.isCancelled {
                let player = player
                let reading = await Task.detached { player.health() }.value
                health = reading
                drops = Array((drops + [reading.droppedFrames]).suffix(30))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f Mbit/s", bytesPerSecond * 8 / 1_000_000)
    }
}

/// Measures the screen's refresh rate from the timing of its frames; mpv can't see it here.
private final class ScreenRate: NSObject, ObservableObject {
    @Published private(set) var rate = 0.0
    private var link: CADisplayLink?

    override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // A slow tick is enough to read the frame length from.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 2, preferred: 1)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    deinit { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        guard link.duration > 0 else { return }
        let measured = (1 / link.duration).rounded()
        if measured != rate { rate = measured }
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
