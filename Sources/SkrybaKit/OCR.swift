import Foundation
import Vision
import AppKit
import PDFKit
import CoreGraphics

/// Rozpoznawanie tekstu z obrazów (Vision, w pełni lokalnie, z polskim).
/// Używane dla plików graficznych, skanowanych PDF-ów i prezentacji z obrazami.
enum OCR {

    /// Preferowane języki rozpoznawania (zawężane do faktycznie wspieranych).
    static let preferredLanguages = ["pl-PL", "en-US"]

    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = preferredLanguages.filter { supported.contains($0) }
        return wanted.isEmpty ? Array(supported.prefix(2)) : wanted
    }

    /// OCR pojedynczego obrazu.
    static func recognize(cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = supportedLanguages()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// OCR pliku graficznego (PNG/JPG/HEIC/TIFF…).
    static func recognizeImageFile(_ url: URL) throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SkrybaError.documentReadFailed(url.lastPathComponent)
        }
        return recognize(cgImage: cg)
    }

    /// OCR danych obrazu (np. grafiki osadzonej w pptx).
    static func recognizeImageData(_ data: Data) -> String {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return recognize(cgImage: cg)
    }

    /// OCR wszystkich stron PDF (renderuje strony do bitmap). Dla skanów.
    static func recognizePDF(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = renderPage(page) else { continue }
            let text = recognize(cgImage: cg).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func renderPage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
