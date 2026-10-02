import AppKit
import SwiftUI

struct VideoView: NSViewRepresentable {
    let player: MPVPlayer

    func makeNSView(context: Context) -> VideoHostView {
        VideoHostView(player: player)
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}

final class VideoHostView: NSView {
    init(player: MPVPlayer) {
        super.init(frame: .zero)
        layer = MPVVideoLayer(player: player)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
