import SwiftUI
import AppKit
import PDFKit
import SkrybaKit

/// Płótno edytora: PDFView z nakładką przechwytującą gesty narzędzi.
struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel

    func makeNSView(context: Context) -> PDFEditorContainer {
        let container = PDFEditorContainer()
        container.model = model
        container.setup()
        return container
    }

    func updateNSView(_ nsView: PDFEditorContainer, context: Context) {
        nsView.sync()
    }
}

/// Kontener trzymający PDFView i nakładkę narzędzi (tej samej wielkości, na wierzchu).
final class PDFEditorContainer: NSView {
    let pdfView = PDFView()
    lazy var overlay = ToolOverlay(pdfView: pdfView)
    weak var model: PDFEditorModel?
    private var lastRevision = -1
    private var shownDocument: PDFDocument?

    func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.windowBackgroundColor

        addSubview(pdfView)
        addSubview(overlay)
        for v in [pdfView, overlay] {
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        overlay.model = model
    }

    func sync() {
        guard let model else { return }
        overlay.model = model
        overlay.tool = model.tool

        if shownDocument !== model.document {
            shownDocument = model.document
            pdfView.document = model.document
        }
        if lastRevision != model.revision {
            lastRevision = model.revision
            pdfView.layoutDocumentView()
            overlay.needsDisplay = true
        }
    }
}

/// Przezroczysta warstwa na wierzchu PDFView. W trybie „Wskaźnik" przepuszcza
/// kliknięcia do PDFView; w pozostałych narzędziach przechwytuje gesty.
final class ToolOverlay: NSView {
    weak var model: PDFEditorModel?
    var tool: PDFEditorModel.Tool = .select { didSet { window?.invalidateCursorRects(for: self) } }

    private let pdfView: PDFView
    private var strokePoints: [NSPoint] = []   // w układzie nakładki (podgląd na żywo)
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // W trybie wskaźnika klik przechodzi do PDFView (zaznaczanie, przewijanie).
        tool == .select ? nil : self
    }

    override var isFlipped: Bool { false }

    // MARK: - Mysz

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            super.mouseDown(with: event)
        case .draw, .whiteout:
            strokePoints = [p]; dragStart = p; dragCurrent = p
        case .signature:
            commitSignature(at: p)
        case .text:
            commitText(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .draw:
            strokePoints.append(p); needsDisplay = true
        case .whiteout:
            dragCurrent = p; needsDisplay = true
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .draw: commitInk()
        case .whiteout: commitWhiteout()
        default: break
        }
        strokePoints = []; dragStart = nil; dragCurrent = nil; needsDisplay = true
    }

    // MARK: - Podgląd na żywo

    override func draw(_ dirtyRect: NSRect) {
        if tool == .draw, strokePoints.count > 1 {
            (model?.nsInkColor ?? .black).setStroke()
            let path = NSBezierPath()
            path.lineWidth = CGFloat(model?.inkWidth ?? 2)
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: strokePoints[0])
            for pt in strokePoints.dropFirst() { path.line(to: pt) }
            path.stroke()
        }
        if tool == .whiteout, let a = dragStart, let b = dragCurrent {
            let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSColor.systemBlue.setStroke()
            let bez = NSBezierPath(rect: rect); bez.fill(); bez.lineWidth = 1; bez.stroke()
        }
    }

    // MARK: - Konwersja i zatwierdzanie

    private func pageAndPoint(_ overlayPoint: NSPoint) -> (Int, NSPoint, PDFPage)? {
        let inPDF = pdfView.convert(overlayPoint, from: self)
        guard let page = pdfView.page(for: inPDF, nearest: true),
              let index = pdfView.document?.index(for: page) else { return nil }
        return (index, pdfView.convert(inPDF, to: page), page)
    }

    private func commitSignature(at p: NSPoint) {
        guard let (index, pagePoint, _) = pageAndPoint(p) else { return }
        model?.placeSignature(onPage: index, at: pagePoint)
    }

    private func commitText(at p: NSPoint) {
        guard let (index, pagePoint, _) = pageAndPoint(p) else { return }
        let alert = NSAlert()
        alert.messageText = "Wpisz tekst"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Dodaj")
        alert.addButton(withTitle: "Anuluj")
        if alert.runModal() == .alertFirstButtonReturn {
            model?.addText(field.stringValue, onPage: index, at: pagePoint)
        }
    }

    private func commitWhiteout() {
        guard let a = dragStart, let b = dragCurrent else { return }
        let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Stronę i układ bierzemy ze środka zaznaczenia — bez force-unwrap.
        guard let (index, _, page) = pageAndPoint(mid) else { return }
        let pa = pdfView.convert(pdfView.convert(a, from: self), to: page)
        let pb = pdfView.convert(pdfView.convert(b, from: self), to: page)
        let rect = NSRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
        model?.addWhiteout(onPage: index, rect: rect)
    }

    private func commitInk() {
        guard strokePoints.count > 1, let first = strokePoints.first,
              let (index, _, page) = pageAndPoint(first) else { return }
        let path = NSBezierPath()
        let start = pdfView.convert(pdfView.convert(first, from: self), to: page)
        path.move(to: start)
        for pt in strokePoints.dropFirst() {
            let pp = pdfView.convert(pdfView.convert(pt, from: self), to: page)
            path.line(to: pp)
        }
        model?.addInk(onPage: index, path: path)
    }

    // Kursor zależny od narzędzia.
    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }
}
