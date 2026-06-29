import Foundation
import AppKit
import PDFKit
import CoreText

/// Konwersja dokumentów między formatami. Wszystko sprowadzamy do
/// `NSAttributedString` (tekst bogaty), a następnie zapisujemy do celu.
///
/// Operacje oparte o AppKit text system (importery/eksportery HTML/DOCX/ODT/RTF)
/// wymagają głównego wątku, dlatego są opakowane w `MainActor.run`. Ciężka praca
/// (I/O, unzip, osascript, render PDF) biegnie poza głównym wątkiem.
public enum DocumentConverter {

    public static func detect(_ url: URL) -> DocumentFormat? { DocumentFormat.detect(url) }

    public static func targets(for url: URL, includeAppleApps: Bool) -> [DocumentFormat] {
        guard let source = detect(url) else { return [] }
        return DocumentFormat.targets(for: source, includeAppleApps: includeAppleApps)
    }

    /// Konwertuje `input` do `target` i zapisuje w `outputDirectory`.
    @discardableResult
    public static func convert(
        input: URL,
        to target: DocumentFormat,
        outputDirectory: URL,
        shouldCancel: (() -> Bool)? = nil
    ) async throws -> URL {
        guard let source = detect(input) else {
            throw SkrybaError.unsupportedDocument(input.lastPathComponent)
        }
        if shouldCancel?() == true { throw SkrybaError.cancelled }

        let attributed = try await read(url: input, format: source, shouldCancel: shouldCancel)
        if shouldCancel?() == true { throw SkrybaError.cancelled }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stem = input.deletingPathExtension().lastPathComponent
        var outURL = outputDirectory.appendingPathComponent(stem).appendingPathExtension(target.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: outURL.path) {
            outURL = outputDirectory.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(target.fileExtension)
            counter += 1
        }

        try await write(attributed, to: outURL, format: target)
        return outURL
    }

    // MARK: - Odczyt → NSAttributedString

    static func read(url: URL, format: DocumentFormat, shouldCancel: (() -> Bool)? = nil) async throws -> NSAttributedString {
        switch format {
        case .txt:
            return NSAttributedString(string: try readText(url))
        case .md:
            let html = Markdown.toHTML(try readText(url))
            return try await MainActor.run { try attributedFromHTML(html) }
        case .rtf, .html, .docx, .odt:
            let type = documentType(for: format)
            return try await MainActor.run {
                try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            }
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw SkrybaError.documentReadFailed(url.lastPathComponent) }
            return NSAttributedString(string: doc.string ?? "")
        case .pptx, .xlsx:
            return NSAttributedString(string: try OfficeText.extractText(from: url, format: format))
        case .key, .numbers, .pages:
            return NSAttributedString(string: try iWorkBridge.extractText(from: url, format: format, shouldCancel: shouldCancel))
        }
    }

    static func attributedFromHTML(_ html: String) throws -> NSAttributedString {
        guard let data = html.data(using: .utf8) else { throw SkrybaError.documentReadFailed("html") }
        return try NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
    }

    // MARK: - Zapis ← NSAttributedString

    static func write(_ attr: NSAttributedString, to url: URL, format: DocumentFormat) async throws {
        let range = NSRange(location: 0, length: attr.length)
        switch format {
        case .txt:
            try attr.string.write(to: url, atomically: true, encoding: .utf8)
        case .md:
            let md = await MainActor.run { Markdown.fromAttributed(attr) }
            try md.write(to: url, atomically: true, encoding: .utf8)
        case .rtf, .html, .docx, .odt:
            let type = documentType(for: format)
            let data = try await MainActor.run {
                try attr.data(from: range, documentAttributes: [.documentType: type])
            }
            try data.write(to: url)
        case .pdf:
            try PDFRenderer.pdfData(from: attr).write(to: url)
        case .pptx, .xlsx, .key, .numbers, .pages:
            throw SkrybaError.unsupportedTarget(format.displayName)
        }
    }

    // MARK: - Pomocnicze

    private static func readText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try String(contentsOf: url) // autodetekcja kodowania, błąd się propaguje
    }

    private static func documentType(for format: DocumentFormat) -> NSAttributedString.DocumentType {
        switch format {
        case .rtf: return .rtf
        case .html: return .html
        case .docx: return .officeOpenXML
        case .odt: return .openDocument
        default: return .plain
        }
    }
}

/// Render NSAttributedString do wielostronicowego PDF (Core Text — bezpieczny wątkowo).
enum PDFRenderer {
    static func pdfData(from attr: NSAttributedString) -> Data {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 54
        let textRect = CGRect(x: margin, y: margin, width: pageWidth - 2 * margin, height: pageHeight - 2 * margin)

        let body: NSAttributedString = attr.length > 0 ? attr : NSAttributedString(string: " ")
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(body as CFAttributedString)
        let path = CGPath(rect: textRect, transform: nil)
        let total = body.length
        var start = 0

        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 {
                // Strona nie zmieściła ani znaku (patologiczny rozmiar) — wymuś postęp,
                // by nie zgubić ogona dokumentu ani nie zapętlić się.
                start += 1
            } else {
                start += visible.length
            }
        } while start < total

        ctx.closePDF()
        return data as Data
    }
}
