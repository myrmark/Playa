import Foundation
import Libmpv
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Thin wrapper around a libmpv handle. mpv draws straight into `videoLayer`
/// with Metal (through MoltenVK), on its own thread.
final class MPVPlayer: ObservableObject {
    struct Track: Identifiable, Hashable {
        enum Kind { case audio, subtitle }
        let kind: Kind
        let trackID: Int
        let label: String
        let isSelected: Bool

        var id: String { "\(kind)-\(trackID)" }
    }

    @Published var isPaused = false { didSet { updateKeepAwake() } }
    @Published var isBuffering = false
    @Published var errorMessage: String? { didSet { updateKeepAwake() } }
    /// True while a dropped live stream is being reopened.
    @Published private(set) var isReconnecting = false
    /// True when a live stream stopped and can be reopened by hand.
    @Published private(set) var canRetry = false
    /// Audio and subtitle tracks of the current stream.
    @Published private(set) var tracks: [Track] = []
    /// Playback position and length in seconds. `duration` is 0 when unknown (live TV).
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var volume: Double = 100 {
        didSet {
            let volume = volume
            queue.async { mpv_set_property_string(self.mpv, "volume", String(volume)) }
        }
    }

    @Published var isMuted = false {
        didSet {
            let isMuted = isMuted
            queue.async { mpv_set_property_string(self.mpv, "mute", isMuted ? "yes" : "no") }
        }
    }

    private let mpv: OpaquePointer
    /// mpv's synchronous calls can block for seconds while it tears down a network
    /// stream, so they never run on the main thread.
    private let queue = DispatchQueue(label: "mpv-commands", qos: .userInitiated)
    /// The layer mpv renders into; hosted by `VideoHostView`.
    let videoLayer = VideoLayer()

    static let autoReconnectKey = "autoReconnect"
    /// Pause between closing one stream and opening the next. mpv closes the old connection
    /// first, but only milliseconds ahead; a provider that counts connections with any lag
    /// could see two streams on a single-stream subscription.
    private static let switchGap: TimeInterval = 0.7

    /// Number of the most recently requested load, read on the command queue to skip superseded ones.
    private let latestLoad = NSLock()
    private var latestLoadToken = 0
    /// Whether a stream may be open in mpv; command queue only.
    private var streamOpen = false
    /// Whether the aspect ratio currently carries the resize nudge; command queue only.
    private var aspectNudged = false
    private var resizeWork: DispatchWorkItem?

    // Reconnect bookkeeping; main thread only.
    private var currentURL: String? { didSet { updateKeepAwake() } }
    #if os(macOS)
    private var awakeActivity: NSObjectProtocol?
    #endif

    /// Watching involves no input, so the system would otherwise start the screen saver or
    /// sleep the display mid-programme. Held only while something is actually playing.
    private func updateKeepAwake() {
        let isPlaying = currentURL != nil && !isPaused && errorMessage == nil
        DispatchQueue.main.async { [self] in
            #if os(macOS)
            if isPlaying, awakeActivity == nil {
                awakeActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
            } else if !isPlaying, let activity = awakeActivity {
                ProcessInfo.processInfo.endActivity(activity)
                awakeActivity = nil
            }
            #else
            UIApplication.shared.isIdleTimerDisabled = isPlaying
            #endif
        }
    }
    private var isLive = false
    /// Whether the current stream has shown a picture at least once.
    private var hasStarted = false
    private var retries = 0
    /// When the picture last (re)appeared; a reconnect only counts as successful if it then held.
    private var lastStart = Date.distantPast
    /// Identifies the latest load, so a scheduled retry for an abandoned channel does nothing.
    private var loadToken = 0

    init() {
        mpv = mpv_create()
        videoLayer.framebufferOnly = true
        videoLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // mpv takes the layer as an integer "window id" and must have it before it initialises.
        var layerAddress = Int64(Int(bitPattern: Unmanaged.passUnretained(videoLayer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerAddress)
        mpv_set_option_string(mpv, "vo", "gpu-next")
        mpv_set_option_string(mpv, "gpu-api", "vulkan")
        mpv_set_option_string(mpv, "gpu-context", "moltenvk")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "keep-open", "yes")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "64MiB")
        mpv_set_option_string(mpv, "network-timeout", "15")
        mpv_set_option_string(mpv, "input-default-bindings", "no")
        // Streams are direct URLs; the youtube-dl fallback only adds delay and confusing errors.
        mpv_set_option_string(mpv, "ytdl", "no")
        // None of mpv's built-in Lua scripts (on-screen controller, stats, console) are used.
        // Leaving them out also means no LuaJIT, which the hardened runtime would need an exception for.
        mpv_set_option_string(mpv, "load-scripts", "no")
        mpv_set_option_string(mpv, "osc", "no")
        mpv_set_option_string(mpv, "load-stats-overlay", "no")
        mpv_set_option_string(mpv, "load-osd-console", "no")
        mpv_set_option_string(mpv, "load-auto-profiles", "no")
        mpv_set_option_string(mpv, "load-select", "no")
        mpv_set_option_string(mpv, "load-commands", "no")
        mpv_set_option_string(mpv, "load-context-menu", "no")
        mpv_set_option_string(mpv, "load-positioning", "no")
        mpv_initialize(mpv)
        videoLayer.onResize = { [weak self] in self?.surfaceResized() }

        // PLAYA_MPV_LOG=v (or debug) prints mpv's own log to stderr when run from a terminal.
        mpv_request_log_messages(mpv, ProcessInfo.processInfo.environment["PLAYA_MPV_LOG"] ?? "warn")
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list", MPV_FORMAT_NONE)

        let handle = mpv
        let thread = Thread { [weak self] in
            while true {
                guard let event = mpv_wait_event(handle, -1)?.pointee else { continue }
                if event.event_id == MPV_EVENT_SHUTDOWN { break }
                self?.handle(event)
            }
        }
        thread.name = "mpv-events"
        thread.start()
    }

    /// - Parameter isLive: live streams are reopened automatically when they drop.
    func play(url: String, startAt start: Double? = nil, isLive: Bool = false) {
        currentURL = url
        self.isLive = isLive
        hasStarted = false
        retries = 0
        isReconnecting = false
        tracks = []
        load(url, startAt: start)
    }

    /// Reopens a live stream that stopped.
    func retry() {
        guard let url = currentURL else { return }
        retries = 0
        load(url, startAt: nil)
    }

    private func load(_ url: String, startAt start: Double?) {
        loadToken += 1
        canRetry = false
        errorMessage = nil
        isBuffering = true
        position = 0
        duration = 0
        let token = loadToken
        latestLoad.withLock { latestLoadToken = token }
        queue.async {
            if self.streamOpen {
                self.run(["stop"])
                self.streamOpen = false
                Thread.sleep(forTimeInterval: Self.switchGap)
            }
            // Zapping quickly through channels opens only the one that was landed on.
            guard self.latestLoad.withLock({ self.latestLoadToken }) == token else { return }
            // The resize nudge belongs to the previous stream's aspect ratio.
            mpv_set_property_string(self.mpv, "video-aspect-override", "-1")
            self.aspectNudged = false
            if let start {
                self.run(["loadfile", url, "replace", "-1", "start=\(Int(start))"])
            } else {
                self.run(["loadfile", url])
            }
            self.streamOpen = true
            mpv_set_property_string(self.mpv, "pause", "no")
        }
    }

    /// mpv's Metal output only reads the layer's size when the video output is reconfigured,
    /// which normally happens once per stream. After a window resize or a device rotation it
    /// would keep laying the picture out for the old size, leaving it small in one corner.
    ///
    /// Reconfiguring needs the picture's parameters to change, so this nudges the aspect ratio
    /// by a hundredth of a percent, or back again. The difference is far below a pixel.
    private func surfaceResized() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.aspectNudged {
                mpv_set_property_string(self.mpv, "video-aspect-override", "-1")
                self.aspectNudged = false
                return
            }
            var aspect = 0.0
            // No picture yet: the stream will be laid out for the current size when it starts.
            guard mpv_get_property(self.mpv, "video-params/aspect", MPV_FORMAT_DOUBLE, &aspect) >= 0, aspect > 0 else { return }
            mpv_set_property_string(self.mpv, "video-aspect-override", String(format: "%.6f", aspect * 1.0001))
            self.aspectNudged = true
        }
        resizeWork = work
        // A window being dragged changes size continuously; act once it settles.
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func togglePause() {
        command(["cycle", "pause"])
    }

    func seek(to seconds: Double) {
        position = seconds
        command(["seek", String(seconds), "absolute"])
    }

    func stop() {
        currentURL = nil
        queue.async {
            self.run(["stop"])
            self.streamOpen = false
        }
    }

    func selectAudio(_ track: Track) {
        queue.async { mpv_set_property_string(self.mpv, "aid", String(track.trackID)) }
    }

    /// Pass nil to turn subtitles off.
    func selectSubtitle(_ track: Track?) {
        let value = track.map { String($0.trackID) } ?? "no"
        queue.async { mpv_set_property_string(self.mpv, "sid", value) }
    }

    /// Called on the main thread when the stream stopped by itself, with an error or by running dry.
    private func playbackEnded(message: String) {
        guard let url = currentURL else { return }
        // Many providers allow one stream per subscription and ban accounts that open two. A stream
        // often drops precisely because another device started watching, so reopening it without
        // being asked could put a second stream on the account. Reconnecting is therefore opt-in.
        let reconnects = UserDefaults.standard.bool(forKey: Self.autoReconnectKey)
        // Only stable playback counts as a successful reconnect, so repeated cut-offs still end.
        if hasStarted, Date().timeIntervalSince(lastStart) > 60 { retries = 0 }
        // A channel that never started gets one more try; one that was playing gets several.
        let limit = hasStarted ? 5 : 1
        guard isLive, reconnects, retries < limit else {
            isReconnecting = false
            isBuffering = false
            canRetry = isLive
            if isLive || !hasStarted { errorMessage = message }
            return
        }
        retries += 1
        isReconnecting = true
        isBuffering = true
        errorMessage = nil
        let token = loadToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(retries * 2, 10))) {
            guard token == self.loadToken, self.currentURL == url else { return }
            self.load(url, startAt: nil)
        }
    }

    private func propertyString(_ name: String) -> String? {
        guard let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func readTracks() -> [Track] {
        let count = propertyString("track-list/count").flatMap(Int.init) ?? 0
        return (0..<count).compactMap { index in
            let prefix = "track-list/\(index)/"
            guard let type = propertyString(prefix + "type"), type == "audio" || type == "sub",
                  let id = propertyString(prefix + "id").flatMap(Int.init)
            else { return nil }
            let title = propertyString(prefix + "title")
            let language = propertyString(prefix + "lang").map { code in
                Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
            }
            let label: String
            switch (title, language) {
            case let (title?, language?): label = "\(title) (\(language))"
            case let (title?, nil): label = title
            case let (nil, language?): label = language
            case (nil, nil): label = "Track \(id)"
            }
            return Track(
                kind: type == "audio" ? .audio : .subtitle, trackID: id, label: label,
                isSelected: propertyString(prefix + "selected") == "yes"
            )
        }
    }

    private func command(_ arguments: [String]) {
        queue.async { self.run(arguments) }
    }

    /// Runs an mpv command synchronously; call on the command queue.
    private func run(_ arguments: [String]) {
        let strings = arguments.map { strdup($0) }
        var argv: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        argv.append(nil)
        mpv_command(mpv, &argv)
        strings.forEach { free($0) }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { return }
            let name = String(cString: property.name)
            if name == "track-list" {
                let tracks = readTracks()
                DispatchQueue.main.async { self.tracks = tracks }
                return
            }
            if property.format == MPV_FORMAT_DOUBLE, let value = property.data?.assumingMemoryBound(to: Double.self).pointee {
                DispatchQueue.main.async {
                    if name == "duration" {
                        self.duration = value
                    } else if name == "time-pos", Int(value) != Int(self.position) {
                        // Whole seconds are enough for the seek bar; skip the per-frame updates.
                        self.position = value
                    }
                }
                return
            }
            guard property.format == MPV_FORMAT_FLAG,
                  let flag = property.data?.assumingMemoryBound(to: Int32.self).pointee
            else { return }
            DispatchQueue.main.async {
                if name == "pause" { self.isPaused = flag != 0 }
                if name == "paused-for-cache" { self.isBuffering = flag != 0 }
                // With keep-open, a live stream that runs dry stops here instead of ending the file.
                if name == "eof-reached", flag != 0, self.isLive {
                    self.playbackEnded(message: "This channel stopped sending video.")
                }
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            DispatchQueue.main.async {
                self.isBuffering = false
                self.isReconnecting = false
                self.hasStarted = true
                self.lastStart = Date()
            }
        case MPV_EVENT_END_FILE:
            guard let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                  end.reason == MPV_END_FILE_REASON_ERROR
            else { return }
            let message = String(cString: mpv_error_string(end.error))
            DispatchQueue.main.async {
                self.playbackEnded(message: "Could not play this channel (\(message)).")
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let log = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { return }
            FileHandle.standardError.write(Data("[mpv/\(String(cString: log.prefix))] \(String(cString: log.text))".utf8))
        default:
            break
        }
    }
}

final class VideoLayer: CAMetalLayer {
    /// Called when the drawable really changes size: a window resize or a device rotation.
    var onResize: (() -> Void)?

    // MoltenVK briefly sets the drawable to 1x1 to flush a presentation, which makes the
    // picture flicker and can leave it stuck at that size. See mpv-player/mpv#13651.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1, newValue != super.drawableSize {
                super.drawableSize = newValue
                onResize?()
            }
        }
    }
}
