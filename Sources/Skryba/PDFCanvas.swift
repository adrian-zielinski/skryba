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
        // Szeroki zakres skali — właściwe granice pilnuje nakładka (clampScale), a PDFView ich nie obcina.
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 12

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
        // Przypisuj tylko przy realnej zmianie: didSet narzędzia woła deselect() dla narzędzi
        // innych niż Wskaźnik, więc bezwarunkowe przypisanie gubiłoby zaznaczenie przy każdym
        // odświeżeniu SwiftUI (np. bump revision po transformacji).
        if overlay.tool != model.tool { overlay.tool = model.tool }

        if shownDocument !== model.document {
            shownDocument = model.document
            pdfView.document = model.document
            overlay.documentChanged()
        }
        if lastRevision != model.revision {
            lastRevision = model.revision
            pdfView.layoutDocumentView()
            overlay.needsDisplay = true
        }
        if let target = model.scrollToPage, let page = pdfView.document?.page(at: target) {
            pdfView.go(to: page)
            DispatchQueue.main.async { model.scrollToPage = nil }
        }
    }
}

/// Przezroczysta warstwa na wierzchu PDFView. Przechwytuje gesty narzędzi i transformacje
/// zaznaczonej adnotacji; przewijanie i zoom kieruje do wewnętrznego NSScrollView PDFView.
final class ToolOverlay: NSView {
    weak var model: PDFEditorModel?
    var tool: PDFEditorModel.Tool = .select {
        didSet {
            if tool != .select { deselect() }
            window?.invalidateCursorRects(for: self)
        }
    }

    private let pdfView: PDFView
    private var strokePoints: [NSPoint] = []   // w układzie nakładki (podgląd na żywo)
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    // Zaznaczona adnotacja i trwająca transformacja.
    private var selectedAnnotation: PDFAnnotation?
    private var selectedPageIndex: Int?
    private var grabOffset: CGSize?               // od środka adnotacji do punktu chwytu (układ strony)

    private enum ActiveTransform { case move, scale(AnnotationTransform.Handle), rotate }
    private var activeTransform: ActiveTransform?
    // Czy w trakcie tej transformacji realnie przeciągnięto myszą (a nie tylko kliknięto, by zaznaczyć).
    private var didDragTransform = false
    // Podgląd geometrii podczas przeciągania (układ strony zaznaczonej adnotacji).
    private var previewCenter: CGPoint?
    private var previewSize: CGSize?
    private var previewRotation: CGFloat?

    // Wewnętrzny NSScrollView PDFView (do przewijania gestami); unieważniany przy zmianie dokumentu.
    private weak var cachedScrollView: NSScrollView?
    // Baza skali dla trwającego gestu pinch.
    private var magnifyBaseScale: CGFloat?

    private let handleHitRadius: CGFloat = 10

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    // Zawsze przechwytujemy zdarzenia (też w trybie wskaźnika — by zaznaczać/transformować adnotacje).
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func documentChanged() { stopObservingScroll(); cachedScrollView = nil; deselect() }

    /// Przewinięcie/zoom przesuwa treść pod nakładką — przerysuj ramkę i uchwyty zaznaczenia,
    /// bo są rysowane w stałych granicach nakładki, a hit-test liczy pozycje na żywo.
    @objc private func overlayNeedsRedraw() { needsDisplay = true }

    private func stopObservingScroll() {
        if let clip = cachedScrollView?.contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    private func deselect() {
        selectedAnnotation = nil; selectedPageIndex = nil; grabOffset = nil
        activeTransform = nil; previewCenter = nil; previewSize = nil; previewRotation = nil
        needsDisplay = true
    }

    // MARK: - Przewijanie i zoom gestami

    /// Wewnętrzny NSScrollView PDFView. Domyślna NSView.scrollWheel idzie w GÓRĘ łańcucha responderów,
    /// więc przekazanie pdfView.scrollWheel nie przewija — trzeba trafić w scroll view bezpośrednio.
    private func innerScrollView() -> NSScrollView? {
        if let sv = cachedScrollView { return sv }
        let found = Self.firstScrollView(in: pdfView)
        cachedScrollView = found
        // Obserwuj zmiany origin contentView (przewijanie z inercją, zoom) i unieważniaj nakładkę.
        if let clip = found?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(overlayNeedsRedraw),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
        return found
    }
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let sv = sub as? NSScrollView { return sv }
            if let deeper = firstScrollView(in: sub) { return deeper }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoomByScroll(event)
            return
        }
        if let sv = innerScrollView() { sv.scrollWheel(with: event) }
        else { pdfView.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .began {
            pdfView.autoScales = false
            magnifyBaseScale = pdfView.scaleFactor
        }
        let anchor = convert(event.locationInWindow, from: nil)
        zoomAnchored(to: pdfView.scaleFactor * (1 + event.magnification), anchor: anchor)
        if event.phase == .ended || event.phase == .cancelled { magnifyBaseScale = nil }
    }

    /// Dwa palce podwójne stuknięcie: przełącz między dopasowaniem do okna a ~2x w miejscu stuknięcia.
    override func smartMagnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        pdfView.autoScales = false
        let fit = pdfView.scaleFactorForSizeToFit
        if pdfView.scaleFactor <= fit * 1.05 {
            zoomAnchored(to: fit * 2, anchor: anchor)
        } else {
            zoomAnchored(to: fit, anchor: anchor)
        }
    }

    private func zoomByScroll(_ event: NSEvent) {
        pdfView.autoScales = false
        let anchor = convert(event.locationInWindow, from: nil)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        zoomAnchored(to: pdfView.scaleFactor * (1 + delta * 0.01), anchor: anchor)
    }

    private func clampScale(_ s: CGFloat) -> CGFloat {
        let fit = pdfView.scaleFactorForSizeToFit
        let minS = max(0.25, fit * 0.5)
        return min(max(s, minS), 8.0)
    }

    /// Zoom z zakotwiczeniem punktu pod kursorem: origin contentView przesuwamy tak, by ten sam punkt
    /// dokumentu został pod kursorem (documentView skaluje się liniowo ze scaleFactor).
    private func zoomAnchored(to rawScale: CGFloat, anchor: NSPoint) {
        let newScale = clampScale(rawScale)
        let old = pdfView.scaleFactor
        guard abs(newScale - old) > 0.0001 else { return }
        guard let sv = innerScrollView() else { pdfView.scaleFactor = newScale; return }
        let clip = sv.contentView
        let clipPoint = clip.convert(anchor, from: self)   // punkt pod kursorem w układzie documentView (przed zmianą)
        let oldOrigin = clip.bounds.origin
        pdfView.scaleFactor = newScale
        let ratio = newScale / old
        let newOrigin = CGPoint(x: oldOrigin.x + clipPoint.x * (ratio - 1),
                                y: oldOrigin.y + clipPoint.y * (ratio - 1))
        clip.scroll(to: newOrigin)
        sv.reflectScrolledClipView(clip)
    }

    private func zoomCentered(_ rawScale: CGFloat) {
        pdfView.autoScales = false
        zoomAnchored(to: rawScale, anchor: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Mysz

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        // 1. Uchwyt transformacji zaznaczonej adnotacji (skalowanie/obrót)?
        if let annot = selectedAnnotation, let idx = selectedPageIndex,
           let handle = handleHit(at: p, annot: annot, pageIndex: idx) {
            beginTransform(handle, annot: annot)
            return
        }

        // 2. Klik w istniejącą edytowalną adnotację → zaznacz i przygotuj przesuwanie (niezależnie od narzędzia).
        if let hit = hitEditableAnnotation(atOverlay: p) {
            selectedAnnotation = hit.annotation
            selectedPageIndex = hit.index
            beginMove(annot: hit.annotation, grabPage: hit.pagePoint)
            strokePoints = []; dragStart = nil
            needsDisplay = true
            return
        }
        deselect()

        switch tool {
        case .select:
            break // klik w pustkę = odznaczenie
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

        if let annot = selectedAnnotation, let idx = selectedPageIndex, let active = activeTransform {
            guard let pagePoint = overlayToPage(p, pageIndex: idx) else { return }
            didDragTransform = true
            let g = geometry(of: annot)
            switch active {
            case .move:
                if let off = grabOffset {
                    previewCenter = CGPoint(x: pagePoint.x - off.width, y: pagePoint.y - off.height)
                    previewSize = g.size; previewRotation = g.rotation
                }
            case .scale(let handle):
                let proportional = (annot is ImageStampAnnotation) && !event.modifierFlags.contains(.option)
                let r = AnnotationTransform.resize(center: g.center, size: g.size, rotationDegrees: g.rotation,
                                                   handle: handle, toCursor: pagePoint, proportional: proportional)
                previewCenter = r.center; previewSize = r.size; previewRotation = g.rotation
            case .rotate:
                var deg = AnnotationTransform.rotationDegrees(center: g.center, handlePoint: pagePoint)
                if event.modifierFlags.contains(.shift) { deg = AnnotationTransform.snapAngle(deg, step: 15) }
                previewCenter = g.center; previewSize = g.size; previewRotation = deg
            }
            needsDisplay = true
            return
        }

        switch tool {
        case .draw: strokePoints.append(p); needsDisplay = true
        case .whiteout: dragCurrent = p; needsDisplay = true
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let annot = selectedAnnotation, let idx = selectedPageIndex, let active = activeTransform {
            // Commit tylko, gdy realnie przeciągnięto — samo kliknięcie (by pokazać uchwyty)
            // nie może brudzić dokumentu ani przestemplowywać podpisu.
            if didDragTransform { commitTransform(active, annot: annot, pageIndex: idx) }
        } else {
            switch tool {
            case .draw: commitInk()
            case .whiteout: commitWhiteout()
            default: break
            }
        }
        activeTransform = nil
        strokePoints = []; dragStart = nil; dragCurrent = nil
        syncPreviewToSelection()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let annot = selectedAnnotation, let idx = selectedPageIndex,
           let h = handleHit(at: p, annot: annot, pageIndex: idx) {
            cursor(for: h, annot: annot, pageIndex: idx).set()
        } else {
            (tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { deselect(); return }   // Esc — odznaczenie

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoomCentered(pdfView.scaleFactor * 1.25); return
            case "-", "_": zoomCentered(pdfView.scaleFactor / 1.25); return
            case "0": pdfView.autoScales = true; return   // dopasuj do okna
            default: break
            }
        }

        if (event.keyCode == 51 || event.keyCode == 117), let annot = selectedAnnotation, let index = selectedPageIndex {
            model?.deleteAnnotation(annot, onPage: index)
            deselect()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Transformacje adnotacji

    /// Które uchwyty ma dana adnotacja. Obraz (podpis): rogi + obrót. Zamalowanie (Square): 8 uchwytów.
    /// Tekst (FreeText): rogi. Rysunek (Ink) i reszta: brak (tylko przesuwanie).
    private func handles(for annot: PDFAnnotation) -> [AnnotationTransform.Handle] {
        if annot is ImageStampAnnotation {
            return [.topLeft, .topRight, .bottomLeft, .bottomRight, .rotation]
        }
        switch annot.type {
        case "Square":
            return [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        case "FreeText":
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        default:
            return []
        }
    }

    /// Geometria (środek/rozmiar/obrót) adnotacji. Obraz zna swój obrót; reszta jest osiowa (0°).
    private func geometry(of annot: PDFAnnotation) -> (center: CGPoint, size: CGSize, rotation: CGFloat) {
        if let stamp = annot as? ImageStampAnnotation {
            return (stamp.center, stamp.displaySize, stamp.rotationDegrees)
        }
        return (CGPoint(x: annot.bounds.midX, y: annot.bounds.midY), annot.bounds.size, 0)
    }

    private func beginMove(annot: PDFAnnotation, grabPage: CGPoint) {
        let g = geometry(of: annot)
        grabOffset = CGSize(width: grabPage.x - g.center.x, height: grabPage.y - g.center.y)
        activeTransform = .move
        didDragTransform = false
        previewCenter = g.center; previewSize = g.size; previewRotation = g.rotation
    }

    private func beginTransform(_ handle: AnnotationTransform.Handle, annot: PDFAnnotation) {
        activeTransform = handle == .rotation ? .rotate : .scale(handle)
        didDragTransform = false
        let g = geometry(of: annot)
        previewCenter = g.center; previewSize = g.size; previewRotation = g.rotation
    }

    private func commitTransform(_ active: ActiveTransform, annot: PDFAnnotation, pageIndex: Int) {
        guard let c = previewCenter, let s = previewSize, let r = previewRotation else { return }
        if let stamp = annot as? ImageStampAnnotation {
            stamp.applyTransform(center: c, displaySize: s, rotationDegrees: r)
            forceRedraw(stamp, pageIndex: pageIndex)   // sam obrót nie zmienia AABB przy kwadracie — wymuś przerysowanie
        } else if annot.type == "FreeText" {
            let oldHeight = annot.bounds.height
            annot.bounds = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
            if oldHeight > 0, let f = annot.font, case .scale = active {
                let scaled = max(6, f.pointSize * (s.height / oldHeight))
                annot.font = NSFont(descriptor: f.fontDescriptor, size: scaled) ?? NSFont.systemFont(ofSize: scaled)
            }
        } else {
            annot.bounds = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
        }
        model?.annotationChanged()
    }

    /// PDFKit potrafi nie odświeżyć samej zmiany obrotu (AABB bez zmian) — zdejmij i dodaj adnotację.
    private func forceRedraw(_ annot: PDFAnnotation, pageIndex: Int) {
        guard let page = pdfView.document?.page(at: pageIndex) else { return }
        page.removeAnnotation(annot)
        page.addAnnotation(annot)
        pdfView.layoutDocumentView()
    }

    private func syncPreviewToSelection() {
        guard let annot = selectedAnnotation else {
            previewCenter = nil; previewSize = nil; previewRotation = nil; return
        }
        let g = geometry(of: annot)
        previewCenter = g.center; previewSize = g.size; previewRotation = g.rotation
    }

    private func handleHit(at p: NSPoint, annot: PDFAnnotation, pageIndex: Int) -> AnnotationTransform.Handle? {
        let g = geometry(of: annot)
        let center = previewCenter ?? g.center
        let size = previewSize ?? g.size
        let rot = previewRotation ?? g.rotation
        var best: AnnotationTransform.Handle?
        var bestDist = handleHitRadius
        for h in handles(for: annot) {
            let pp = AnnotationTransform.handlePoint(h, center: center, size: size, rotationDegrees: rot)
            guard let o = pageToOverlay(pp, pageIndex: pageIndex) else { continue }
            let d = hypot(o.x - p.x, o.y - p.y)
            if d <= bestDist { bestDist = d; best = h }
        }
        return best
    }

    private func cursor(for handle: AnnotationTransform.Handle, annot: PDFAnnotation, pageIndex: Int) -> NSCursor {
        if handle == .rotation { return .openHand }
        let g = geometry(of: annot)
        let center = previewCenter ?? g.center
        let size = previewSize ?? g.size
        let rot = previewRotation ?? g.rotation
        let hp = AnnotationTransform.handlePoint(handle, center: center, size: size, rotationDegrees: rot)
        guard let ho = pageToOverlay(hp, pageIndex: pageIndex),
              let co = pageToOverlay(center, pageIndex: pageIndex) else { return .crosshair }
        return abs(ho.x - co.x) >= abs(ho.y - co.y) ? .resizeLeftRight : .resizeUpDown
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
        drawSelection()
    }

    /// Ramka zaznaczenia (obrócona dla obrazu), uchwyty skalowania i uchwyt obrotu.
    private func drawSelection() {
        guard let annot = selectedAnnotation, let idx = selectedPageIndex else { return }
        let g = geometry(of: annot)
        let center = previewCenter ?? g.center
        let size = previewSize ?? g.size
        let rot = previewRotation ?? g.rotation
        let hs = handles(for: annot)

        let corners: [AnnotationTransform.Handle] = [.bottomLeft, .bottomRight, .topRight, .topLeft]
        let cpts = corners.compactMap { h in
            pageToOverlay(AnnotationTransform.handlePoint(h, center: center, size: size, rotationDegrees: rot),
                          pageIndex: idx)
        }
        guard cpts.count == 4 else { return }

        let frame = NSBezierPath()
        frame.move(to: cpts[0])
        for pt in cpts.dropFirst() { frame.line(to: pt) }
        frame.close()
        if activeTransform != nil {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            frame.fill()
        }
        NSColor.controlAccentColor.setStroke()
        frame.lineWidth = 1.5
        frame.setLineDash([5, 3], count: 2, phase: 0)
        frame.stroke()

        // Uchwyt obrotu: kreska od środka górnej krawędzi do kółka.
        if hs.contains(.rotation) {
            let topMid = AnnotationTransform.handlePoint(.top, center: center, size: size, rotationDegrees: rot)
            let rotPt = AnnotationTransform.handlePoint(.rotation, center: center, size: size, rotationDegrees: rot)
            if let a = pageToOverlay(topMid, pageIndex: idx), let b = pageToOverlay(rotPt, pageIndex: idx) {
                let line = NSBezierPath()
                line.move(to: a); line.line(to: b)
                line.lineWidth = 1.5
                line.stroke()
                drawHandle(at: b, circle: true)
            }
        }
        // Uchwyty skalowania.
        for h in hs where h != .rotation {
            let pp = AnnotationTransform.handlePoint(h, center: center, size: size, rotationDegrees: rot)
            if let o = pageToOverlay(pp, pageIndex: idx) { drawHandle(at: o, circle: false) }
        }
    }

    private func drawHandle(at p: NSPoint, circle: Bool) {
        let side: CGFloat = circle ? 11 : 9
        let rect = NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        let path = circle ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        NSColor.white.setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    // MARK: - Konwersja i zatwierdzanie

    /// Adapter żywego PDFView do `PDFCoordinateSpace`. Sama logika mapowania (overlay → strona,
    /// nearest:true, normalizacja prostokąta) mieszka w SkrybaKit i jest pokryta testami.
    private var coordinateSpace: PDFCoordinateSpace {
        OverlayCoordinateSpace(pdfView: pdfView, overlay: self)
    }

    /// Punkt nakładki → układ konkretnej strony (do transformacji zaznaczonej adnotacji).
    private func overlayToPage(_ p: NSPoint, pageIndex: Int) -> CGPoint? {
        guard let page = pdfView.document?.page(at: pageIndex) else { return nil }
        return pdfView.convert(pdfView.convert(p, from: self), to: page)
    }
    /// Punkt układu strony → nakładka (do rysowania/hit-testu uchwytów).
    private func pageToOverlay(_ p: CGPoint, pageIndex: Int) -> NSPoint? {
        guard let page = pdfView.document?.page(at: pageIndex) else { return nil }
        return convert(pdfView.convert(p, from: page), from: pdfView)
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

    // MARK: - Zaznaczanie adnotacji

    private func hitEditableAnnotation(atOverlay p: NSPoint) -> (annotation: PDFAnnotation, index: Int, pagePoint: CGPoint)? {
        guard let (index, pagePoint) = PDFCoordinateMapper.map(overlayPoint: p, in: coordinateSpace),
              let page = pdfView.document?.page(at: index),
              let annotation = page.annotation(at: pagePoint),
              PDFEditing.isEditable(annotation) else { return nil }
        return (annotation, index, pagePoint)
    }

    // Kursor zależny od narzędzia (bazowy; nad uchwytami nadpisuje mouseMoved).
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
