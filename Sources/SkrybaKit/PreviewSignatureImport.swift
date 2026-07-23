import Foundation
import AppKit
import PDFKit

/// Most do podpisów Apple (Podgląd/Markup). Współczesny macOS trzyma te podpisy w pęku
/// kluczy iCloud, w prywatnej grupie dostępu Apple — aplikacja spoza Apple nie ma do nich
/// dostępu (to sprawa entitlementu, nie zgody użytkownika). Dlatego robimy uczciwy transfer:
/// generujemy jednorazowy PDF-szablon, użytkownik wstawia w nim swoje podpisy w Podglądzie
/// i zapisuje, a my je stąd wyciągamy.
public enum PreviewSignatureImport {

    /// A4 poziomo w punktach (72 dpi). Wymiary stałe, bo szablon musi być deterministyczny.
    public static let pageSize = CGSize(width: 842, height: 595)

    // MARK: - Szablon

    /// Deterministyczny jednostronicowy PDF z polską instrukcją i ramką na podpisy.
    /// Ta sama treść za każdym razem (bez dat/losowości) — ścieżka zapasowa liczy różnicę
    /// pikseli względem świeżo wygenerowanego szablonu, więc render musi być powtarzalny.
    public static func makeImportPDFData() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return data as Data }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return data as Data }

        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        drawTemplate()
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Zapisuje szablon do pliku.
    public static func makeImportPDF(to url: URL) throws {
        try makeImportPDFData().write(to: url)
    }

    /// Rysuje treść strony. Współrzędne liczone od góry (`top`), przeliczane na układ PDF
    /// (origin w lewym-dolnym rogu) w pomocniczych funkcjach.
    private static func drawTemplate() {
        let ink = NSColor.black
        let muted = NSColor(white: 0.30, alpha: 1)

        text("Wstaw tutaj swoje podpisy", top: 44, x: 60,
             font: .systemFont(ofSize: 30, weight: .bold), color: ink)

        text("Skryba przeniesie je do swojej biblioteki podpisów — raz, a potem masz je pod ręką.",
             top: 86, x: 60, font: .systemFont(ofSize: 14), color: muted)

        let steps = [
            "1.  Kliknij ikonę Oznaczeń (ołówek w kółku) na pasku narzędzi u góry.",
            "2.  Rozwiń narzędzie Podpisz i kliknij swój podpis — pojawi się na stronie.",
            "     Powtórz dla każdego podpisu, który chcesz przenieść.",
            "3.  Naciśnij Cmd+S, aby zapisać, i wróć do Skryby.",
        ]
        var y: CGFloat = 128
        for step in steps {
            text(step, top: y, x: 60, font: .systemFont(ofSize: 15), color: ink)
            y += 26
        }

        // Ramka na podpisy poniżej instrukcji.
        let frameTop: CGFloat = 250
        let frameRect = pdfRect(x: 60, top: frameTop,
                                width: pageSize.width - 120,
                                height: pageSize.height - frameTop - 40)
        let path = NSBezierPath(roundedRect: frameRect, xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        NSColor(white: 0.55, alpha: 1).setStroke()
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()

        text("miejsce na podpisy", top: frameTop + 14, x: 76,
             font: .systemFont(ofSize: 12), color: NSColor(white: 0.6, alpha: 1))
    }

    /// Prostokąt w układzie PDF z podanego „od góry".
    private static func pdfRect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: pageSize.height - top - height, width: width, height: height)
    }

    /// Rysuje tekst pozycjonowany od górnej krawędzi strony.
    private static func text(_ string: String, top: CGFloat, x: CGFloat, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attrs)
        let y = pageSize.height - top - size.height
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: - Wyciąganie podpisów

    /// Wyciąga podpisy z zapisanego szablonu (URL).
    public static func extractSignatures(from url: URL) -> [NSImage] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return extractSignatures(from: doc)
    }

    /// Wyciąga podpisy z zapisanego szablonu. Dwie ścieżki:
    /// A) Podgląd wstawił podpis jako adnotację (stamp/ink) — renderujemy każdą adnotację.
    /// B) Podgląd/eksport spłaszczył adnotacje do treści strony — liczymy różnicę pikseli
    ///    względem czystego szablonu i wycinamy klastry różnic.
    public static func extractSignatures(from doc: PDFDocument) -> [NSImage] {
        guard let page = doc.page(at: 0) else { return [] }

        let annotations = page.annotations.filter { PDFEditing.isEditable($0) }
        if !annotations.isEmpty {
            return annotations.compactMap { renderAnnotationSignature($0) }
        }
        return extractByDiff(savedPage: page)
    }

    /// Skala renderu przy wyciąganiu (wysoka rozdzielczość dla ostrego podpisu).
    private static let renderScale: CGFloat = 4

    // MARK: Ścieżka A — adnotacje

    /// Renderuje pojedynczą adnotację na przezroczystym tle i przycina do jej zawartości.
    /// Adnotację rysujemy w pełnej ramce strony (tak jak przy spłaszczaniu — inaczej PDFKit
    /// potrafi nie narysować adnotacji ink), a potem wycinamy sam ślad. Gdy render wyjdzie
    /// nieprzezroczysty (białe tło z Podglądu) — przepuszczamy przez `removeBackground`.
    static func renderAnnotationSignature(_ annotation: PDFAnnotation, scale: CGFloat = renderScale) -> NSImage? {
        guard let full = renderAnnotationOnPage(annotation, scale: scale, white: false) else { return nil }

        // Nic nie narysowano wprost (np. adnotacja bez strumienia wyglądu) — render na białym + wycięcie.
        guard alphaProfile(full) != .empty, let trimmed = trimTransparent(full) else {
            guard let onWhite = renderAnnotationOnPage(annotation, scale: scale, white: true) else { return nil }
            let img = NSImage(cgImage: onWhite, size: NSSize(width: onWhite.width, height: onWhite.height))
            return SignatureProcessor.removeBackground(img) ?? img
        }

        let img = NSImage(cgImage: trimmed, size: NSSize(width: trimmed.width, height: trimmed.height))
        // Kadr oceniamy dopiero po przycięciu: podpis z Podglądu bywa nieprzezroczystym
        // stemplem na białym tle — wtedy wycinamy tło. Ink ma już realne alfa — zostawiamy.
        if alphaProfile(trimmed) == .opaque {
            return SignatureProcessor.removeBackground(img) ?? img
        }
        return img
    }

    /// Rysuje wyłącznie tę jedną adnotację w ramce całej strony (przezroczyste lub białe tło).
    private static func renderAnnotationOnPage(_ annotation: PDFAnnotation, scale: CGFloat, white: Bool) -> CGImage? {
        let pageBounds = annotation.page?.bounds(for: .mediaBox)
            ?? CGRect(origin: .zero, size: pageSize)
        let w = Int((pageBounds.width * scale).rounded())
        let h = Int((pageBounds.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if white {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -pageBounds.origin.x, y: -pageBounds.origin.y)
        annotation.draw(with: .mediaBox, in: ctx)
        return ctx.makeImage()
    }

    // MARK: Ścieżka B — różnica pikseli

    private static func extractByDiff(savedPage: PDFPage) -> [NSImage] {
        guard let saved = renderOnWhite(savedPage, scale: renderScale) else { return [] }
        guard let templatePage = PDFDocument(data: makeImportPDFData())?.page(at: 0),
              let template = renderOnWhite(templatePage, scale: renderScale),
              template.width == saved.width, template.height == saved.height else { return [] }

        let w = saved.width, h = saved.height
        let mask = differenceMask(saved: saved.px, template: template.px, width: w, height: h)
        let gap = max(4, Int(0.03 * Double(w)))         // sklejaj komponenty bliżej niż ~3% szerokości
        let minPixels = max(80, (w * h) / 12000)        // odrzuć drobny szum
        let boxes = clusters(mask: mask, width: w, height: h, mergeGap: gap, minPixels: minPixels)

        var results: [NSImage] = []
        for box in boxes {
            guard let cropped = saved.cg.cropping(to: box) else { continue }
            let img = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            results.append(SignatureProcessor.removeBackground(img) ?? img)
        }
        return results
    }

    /// Render strony (z adnotacjami) na białym tle. Zwraca bufor pikseli i gotowy obraz do wycinania.
    static func renderOnWhite(_ page: PDFPage, scale: CGFloat)
        -> (cg: CGImage, px: [UInt8], width: Int, height: Int)? {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, px, w, h)
    }

    /// Deterministyczny render strony 0 do bufora pikseli (do porównań w testach).
    public static func renderForComparison(_ doc: PDFDocument, scale: CGFloat = 2)
        -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let page = doc.page(at: 0), let r = renderOnWhite(page, scale: scale) else { return nil }
        return (r.px, r.width, r.height)
    }

    /// Maska pikseli różniących się jasnością powyżej progu.
    private static func differenceMask(saved: [UInt8], template: [UInt8], width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        let threshold = 36
        for p in 0..<(width * height) {
            let i = p * 4
            let ls = (299 * Int(saved[i]) + 587 * Int(saved[i + 1]) + 114 * Int(saved[i + 2])) / 1000
            let lt = (299 * Int(template[i]) + 587 * Int(template[i + 1]) + 114 * Int(template[i + 2])) / 1000
            if abs(ls - lt) > threshold { mask[p] = true }
        }
        return mask
    }

    /// Spójne komponenty maski (8-sąsiedztwo), sklejone gdy bliżej niż `mergeGap`, w układzie
    /// obrazu (origin lewy-górny) — gotowe do `cropping(to:)`.
    private static func clusters(mask: [Bool], width: Int, height: Int,
                                 mergeGap: Int, minPixels: Int) -> [CGRect] {
        var visited = [Bool](repeating: false, count: width * height)
        var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        var stack: [Int] = []

        for start in 0..<(width * height) where mask[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var minX = width, minY = height, maxX = -1, maxY = -1
            var count = 0
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let np = ny * width + nx
                        if mask[np] && !visited[np] { visited[np] = true; stack.append(np) }
                    }
                }
            }
            if count >= minPixels {
                boxes.append((minX, minY, maxX, maxY))
            }
        }

        return mergeBoxes(boxes, gap: mergeGap).map {
            CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX + 1, height: $0.maxY - $0.minY + 1)
        }
    }

    /// Sklejanie prostokątów, których odstęp (po rozszerzeniu o `gap`) się nakłada.
    private static func mergeBoxes(_ input: [(minX: Int, minY: Int, maxX: Int, maxY: Int)], gap: Int)
        -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
        var boxes = input
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    let a = boxes[i], b = boxes[j]
                    let overlapX = a.minX - gap <= b.maxX && b.minX - gap <= a.maxX
                    let overlapY = a.minY - gap <= b.maxY && b.minY - gap <= a.maxY
                    if overlapX && overlapY {
                        boxes[i] = (min(a.minX, b.minX), min(a.minY, b.minY),
                                    max(a.maxX, b.maxX), max(a.maxY, b.maxY))
                        boxes.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return boxes
    }

    // MARK: - Pomocnicze operacje na pikselach

    private enum AlphaProfile { case empty, transparent, opaque }

    /// Ocena kanału alfa: czy w ogóle coś narysowano i czy tło jest przezroczyste.
    private static func alphaProfile(_ cg: CGImage) -> AlphaProfile {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return .empty }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hasOpaque = false, hasTransparent = false
        for p in stride(from: 3, to: px.count, by: 4) {
            if px[p] > 200 { hasOpaque = true }
            else if px[p] < 24 { hasTransparent = true }
            if hasOpaque && hasTransparent { break }
        }
        if !hasOpaque { return .empty }
        return hasTransparent ? .transparent : .opaque
    }

    /// Przycięcie przezroczystych marginesów (dla renderu adnotacji z realnym alfa).
    private static func trimTransparent(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 12 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 6
        let cx = max(0, minX - pad), cy = max(0, minY - pad)
        let cw = min(w - cx, maxX - minX + 1 + 2 * pad)
        let ch = min(h - cy, maxY - minY + 1 + 2 * pad)
        return cg.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch))
    }
}
