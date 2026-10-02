import AppKit
import SwiftUI

struct VideoView: NSViewRepresentable {
    let player: MPVPlayer

    func makeNSView(context: Context) -> VideoHostView {
        VideoHostView(layer: player.videoLayer)
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}

final class VideoHostView: NSView {
    private let videoLayer: CAMetalLayer

    init(layer: CAMetalLayer) {
        videoLayer = layer
        super.init(frame: .zero)
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
