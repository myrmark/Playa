import AppKit
import Cmpv
import OpenGL.GL3

/// Thin wrapper around a libmpv handle. Video is drawn by `MPVVideoLayer`
/// through mpv's OpenGL render API.
final class MPVPlayer: ObservableObject {
    struct Track: Identifiable, Hashable {
        enum Kind { case audio, subtitle }
        let kind: Kind
        let trackID: Int
        let label: String
        let isSelected: Bool

        var id: String { "\(kind)-\(trackID)" }
    }

    @Published var isPaused = false
    @Published var isBuffering = false
    @Published var errorMessage: String?
    /// True while a dropped live stream is being reopened.
    @Published private(set) var isReconnecting = false
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

    private let mpv: OpaquePointer
    /// mpv's synchronous calls can block for seconds while it tears down a network
    /// stream, so they never run on the main thread.
    private let queue = DispatchQueue(label: "mpv-commands", qos: .userInitiated)
    fileprivate var renderContext: OpaquePointer?

    // Reconnect bookkeeping; main thread only.
    private var currentURL: String?
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
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "hwdec", "auto-safe")
        mpv_set_option_string(mpv, "keep-open", "yes")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "64MiB")
        mpv_set_option_string(mpv, "network-timeout", "15")
        mpv_set_option_string(mpv, "input-default-bindings", "no")
        // Streams are direct URLs; the youtube-dl fallback only adds delay and confusing errors.
        mpv_set_option_string(mpv, "ytdl", "no")
        mpv_initialize(mpv)

        mpv_request_log_messages(mpv, "warn")
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

    private func load(_ url: String, startAt start: Double?) {
        loadToken += 1
        errorMessage = nil
        isBuffering = true
        position = 0
        duration = 0
        if let start {
            command(["loadfile", url, "replace", "-1", "start=\(Int(start))"])
        } else {
            command(["loadfile", url])
        }
        queue.async { mpv_set_property_string(self.mpv, "pause", "no") }
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
        command(["stop"])
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
        // Providers often allow one stream at a time. If another device takes it, each reconnect
        // here is cut off again within seconds; counting only stable playback as success makes
        // Playa give up after a few tries instead of fighting that device forever.
        if hasStarted, Date().timeIntervalSince(lastStart) > 60 { retries = 0 }
        // A channel that never started gets one more try; one that was playing gets several.
        let limit = hasStarted ? 5 : 1
        guard isLive, retries < limit else {
            isReconnecting = false
            isBuffering = false
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
        queue.async {
            let strings = arguments.map { strdup($0) }
            var argv: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
            argv.append(nil)
            mpv_command(self.mpv, &argv)
            strings.forEach { free($0) }
        }
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

    // MARK: Rendering

    /// Must be called with the layer's OpenGL context current.
    fileprivate func createRenderContext(for layer: MPVVideoLayer) {
        guard renderContext == nil else { return }
        let api = strdup("opengl")
        defer { free(api) }
        var glParams = mpv_opengl_init_params()
        glParams.get_proc_address = { _, name in
            // RTLD_DEFAULT
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        withUnsafeMutablePointer(to: &glParams) { glParamsPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glParamsPointer)),
                mpv_render_param(),
            ]
            let status = mpv_render_context_create(&renderContext, mpv, &params)
            if status < 0 {
                NSLog("mpv_render_context_create failed: %s", mpv_error_string(status))
            }
        }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, { context in
            let layer = Unmanaged<MPVVideoLayer>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(layer).toOpaque())
    }
}

final class MPVVideoLayer: CAOpenGLLayer {
    private let player: MPVPlayer

    init(player: MPVPlayer) {
        self.player = player
        super.init()
        isOpaque = true
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        player = (layer as! MPVVideoLayer).player
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        return pixelFormat ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        CGLSetCurrentContext(context)
        player.createRenderContext(for: self)
        return context
    }

    override func draw(
        inCGLContext context: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime time: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        guard let renderContext = player.renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var fbo = mpv_opengl_fbo(fbo: framebuffer, w: viewport[2], h: viewport[3], internal_format: 0)
        var flipY: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
    }
}
