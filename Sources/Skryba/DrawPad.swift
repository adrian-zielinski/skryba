import SwiftUI
import AppKit

/// Pole do narysowania podpisu myszką/trackpadem.
struct DrawPad: NSViewRepresentable {
    let nsView = DrawPadNSView()

    func makeNSView(context: Context) -> DrawPadNSView { nsView }
    func updateNSView(_ nsView: DrawPadNSView, context: Context) {}

    func clear() { nsView.clear() }
    var paths: [NSBezierPath] { nsView.paths }
    var size: NSSize { nsView.bounds.size }
}

final class DrawPadNSView: NSView {
    private(set) var paths: [NSBezierPath] = []
    private var current: NSBezierPath?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1; frame.stroke()

        NSColor.black.setStroke()
        for path in paths {
            path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let path = NSBezierPath()
        path.move(to: p)
        current = path
        paths.append(path)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current?.line(to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = nil
    }

    func clear() {
        paths.removeAll()
        current = nil
        needsDisplay = true
    }
}
