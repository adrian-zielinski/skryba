import Foundation
import PDFKit
import AppKit

/// Adnotacja rysująca obraz (np. podpis). PDFKit nie ma natywnego „image stamp",
/// dlatego rysujemy obraz sami; przy eksporcie jest pieczętowany (flatten).
public final class ImageStampAnnotation: PDFAnnotation {
    public let image: NSImage
    public init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }
    required init?(coder: NSCoder) { nil }
    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.draw(cg, in: bounds)
        context.restoreGState()
    }
}

/// Operacje edytora PDF: strony, adnotacje (nakładki) i eksport ze spłaszczeniem.
public enum PDFEditing {

    // MARK: - Strony

    @discardableResult
    public static func deletePage(_ doc: PDFDocument, at index: Int) -> Bool {
        guard index >= 0, index < doc.pageCount, doc.pageCount > 1 else { return false }
        doc.removePage(at: index)
        return true
    }

    public static func movePage(_ doc: PDFDocument, from: Int, to: Int) {
        guard from != to, from >= 0, from < doc.pageCount, to >= 0, to < doc.pageCount,
              let page = doc.page(at: from) else { return }
        doc.removePage(at: from)
        doc.insert(page, at: to > from ? to - 1 : to)
    }

    @discardableResult
    public static func insert(_ doc: PDFDocument, pagesFrom other: PDFDocument, at index: Int) -> Int {
        var inserted = 0
        let at = min(max(0, index), doc.pageCount)
        for i in 0..<other.pageCount {
            guard let page = other.page(at: i)?.copy() as? PDFPage else { continue }
            doc.insert(page, at: at + inserted)
            inserted += 1
        }
        return inserted
    }

    @discardableResult
    public static func insertImagePage(_ doc: PDFDocument, image: NSImage, at index: Int) -> Bool {
        guard let page = PDFPage(image: image) else { return false }
        doc.insert(page, at: min(max(0, index), doc.pageCount))
        return true
    }

    /// Wstaw strony z pliku (PDF albo obraz) na pozycji `index`.
    @discardableResult
    public static func insertFile(_ doc: PDFDocument, url: URL, at index: Int) -> Int {
        if let other = PDFDocument(url: url) {
            return insert(doc, pagesFrom: other, at: index)
        }
        if let image = NSImage(contentsOf: url) {
            return insertImagePage(doc, image: image, at: index) ? 1 : 0
        }
        return 0
    }

    // MARK: - Adnotacje (nakładki)

    /// Białe pole zasłaniające fragment (do „zamaluj i napisz").
    public static func addWhiteout(to page: PDFPage, bounds: CGRect) {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = .white
        annotation.interiorColor = .white
        page.addAnnotation(annotation)
    }

    public static func addText(_ text: String, to page: PDFPage, bounds: CGRect,
                               fontSize: CGFloat = 14, color: NSColor = .black) {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: fontSize)
        annotation.fontColor = color
        annotation.color = .clear
        annotation.alignment = .left
        page.addAnnotation(annotation)
    }

    /// Rysunek odręczny (myszka): ślad jako adnotacja typu ink.
    public static func addInk(paths: [NSBezierPath], to page: PDFPage,
                              color: NSColor = .black, lineWidth: CGFloat = 2) {
        guard !paths.isEmpty else { return }
        var bounds = paths.reduce(CGRect.null) { $0.union($1.bounds) }
        if bounds.isNull || bounds.isEmpty { bounds = page.bounds(for: .mediaBox) }
        bounds = bounds.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.color = color
        for path in paths { annotation.add(path) }
        page.addAnnotation(annotation)
    }

    public static func addSignature(image: NSImage, to page: PDFPage, bounds: CGRect) {
        page.addAnnotation(ImageStampAnnotation(image: image, bounds: bounds))
    }

    /// Czy adnotacja jest naszą edytowalną nakładką (do zaznaczania/przesuwania/usuwania).
    /// Pomijamy oryginalne pola formularzy/linki dokumentu.
    public static func isEditable(_ annotation: PDFAnnotation) -> Bool {
        if annotation is ImageStampAnnotation { return true }
        let editable: Set<String> = ["Square", "FreeText", "Ink", "Stamp", "Highlight", "Underline"]
        return editable.contains(annotation.type ?? "")
    }

    // MARK: - Eksport (spłaszczenie)

    /// PDF ze wszystkimi nakładkami wtopionymi na stałe (podpisy, rysunki, tekst).
    /// Treść stron pozostaje wektorowa (tekst nadal zaznaczalny).
    public static func flattenedData(_ doc: PDFDocument) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { return nil }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info: [String: Any] = [
                kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size),
            ]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.saveGState()
            // Treść strony bez adnotacji, potem adnotacje ręcznie (raz, deterministycznie).
            let annotations = page.annotations
            for a in annotations { a.shouldDisplay = false }
            page.draw(with: .mediaBox, to: ctx)
            for a in annotations {
                a.shouldDisplay = true
                ctx.saveGState()
                a.draw(with: .mediaBox, in: ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    @discardableResult
    public static func saveFlattened(_ doc: PDFDocument, to url: URL) -> Bool {
        guard let data = flattenedData(doc) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
