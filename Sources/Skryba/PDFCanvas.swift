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
            let rect = PDFCoordinateMath.normalizedRect(from: a, to: b)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSColor.systemBlue.setStroke()
            let bez = NSBezierPath(rect: rect); bez.fill(); bez.lineWidth = 1; bez.stroke()
        }
    }

    // MARK: - Konwersja i zatwierdzanie

    /// Adapter żywego PDFView do `PDFCoordinateSpace`. Sama logika mapowania (overlay → strona,
    /// nearest:true, normalizacja prostokąta) mieszka w SkrybaKit i jest pokryta testami.
    private var coordinateSpace: PDFCoordinateSpace {
        OverlayCoordinateSpace(pdfView: pdfView, overlay: self)
    }

    private func commitSignature(at p: NSPoint) {
        guard let (index, pagePoint) = PDFCoordinateMapper.map(overlayPoint: p, in: coordinateSpace) else { return }
        model?.placeSignature(onPage: index, at: pagePoint)
    }

    private func commitText(at p: NSPoint) {
        guard let (index, pagePoint) = PDFCoordinateMapper.map(overlayPoint: p, in: coordinateSpace) else { return }
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
        guard let a = dragStart, let b = dragCurrent,
              let (index, rect) = PDFCoordinateMapper.mapDragRect(from: a, to: b, in: coordinateSpace) else { return }
        model?.addWhiteout(onPage: index, rect: rect)
    }

    private func commitInk() {
        guard strokePoints.count > 1,
              let (index, pagePoints) = PDFCoordinateMapper.mapStroke(strokePoints, in: coordinateSpace),
              let first = pagePoints.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for pt in pagePoints.dropFirst() { path.line(to: pt) }
        model?.addInk(onPage: index, path: path)
    }

    // Kursor zależny od narzędzia.
    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }
}

/// Adapter żywego PDFView do `PDFCoordinateSpace` — trzy konwersje PDFKit, których nie da się
/// odtworzyć bez okna. Logika ich używająca (wybór strony, normalizacja) mieszka w SkrybaKit.
private struct OverlayCoordinateSpace: PDFCoordinateSpace {
    let pdfView: PDFView
    let overlay: NSView

    func overlayToView(_ point: CGPoint) -> CGPoint {
        pdfView.convert(point, from: overlay)
    }
    func pageIndex(forViewPoint point: CGPoint) -> Int? {
        guard let page = pdfView.page(for: point, nearest: true),
              let index = pdfView.document?.index(for: page) else { return nil }
        return index
    }
    func viewToPage(_ point: CGPoint, pageIndex: Int) -> CGPoint {
        guard let page = pdfView.document?.page(at: pageIndex) else { return point }
        return pdfView.convert(point, to: page)
    }
}
