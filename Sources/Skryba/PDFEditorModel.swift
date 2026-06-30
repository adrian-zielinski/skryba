import Foundation
import SwiftUI
import AppKit
import PDFKit
import SkrybaKit

@MainActor
final class PDFEditorModel: ObservableObject {

    enum Tool: String, CaseIterable, Identifiable {
        case select, text, draw, whiteout, signature
        var id: String { rawValue }
        var label: String {
            switch self {
            case .select: return "Wskaźnik"
            case .text: return "Tekst"
            case .draw: return "Rysuj"
            case .whiteout: return "Zamaluj"
            case .signature: return "Podpis"
            }
        }
        var systemImage: String {
            switch self {
            case .select: return "cursorarrow"
            case .text: return "textformat"
            case .draw: return "pencil.tip"
            case .whiteout: return "rectangle.fill"
            case .signature: return "signature"
            }
        }
    }

    @Published var document: PDFDocument?
    @Published var documentURL: URL?
    @Published var tool: Tool = .select
    @Published var inkColor: Color = .black
    @Published var inkWidth: Double = 2
    @Published var pageCount = 0
    @Published var sourceFiles: [URL] = []
    @Published var signatures: [URL] = []
    @Published var selectedSignature: URL?
    @Published var statusMessage = "Przeciągnij PDF, aby go edytować"
    @Published var isDirty = false
    /// Bump, by wymusić odświeżenie PDFView i miniatur po zmianach.
    @Published var revision = 0
    /// Żądanie przewinięcia do strony (klik w miniaturę). Płótno realizuje i czyści.
    @Published var scrollToPage: Int?

    let store = SignatureStore.shared

    init() { refreshSignatures() }

    var nsInkColor: NSColor { NSColor(inkColor) }

    // MARK: - Dokument

    func open(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            statusMessage = "Nie udało się otworzyć: \(url.lastPathComponent)"
            return
        }
        document = doc
        documentURL = url
        isDirty = false
        statusMessage = url.lastPathComponent
        bump()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func bump() {
        pageCount = document?.pageCount ?? 0
        revision += 1
    }

    func goTo(_ index: Int) { scrollToPage = index }

    /// Po przesunięciu adnotacji: oznacz zmiany i odśwież widok.
    func annotationChanged() { isDirty = true; revision += 1 }

    func deleteAnnotation(_ annotation: PDFAnnotation, onPage index: Int) {
        document?.page(at: index)?.removeAnnotation(annotation)
        annotationChanged()
    }

    // MARK: - Strony

    func deletePage(_ index: Int) {
        guard let doc = document else { return }
        if doc.pageCount <= 1 { statusMessage = "Nie można usunąć ostatniej strony"; return }
        if PDFEditing.deletePage(doc, at: index) { isDirty = true; bump() }
    }

    func movePage(from: Int, to: Int) {
        guard let doc = document else { return }
        PDFEditing.movePage(doc, from: from, to: to)
        isDirty = true; bump()
    }

    /// Wstaw plik (PDF/obraz) na pozycji `index` (np. ze źródeł lub z dysku).
    func insertFile(_ url: URL, at index: Int) {
        guard let doc = document else { return }
        let added = PDFEditing.insertFile(doc, url: url, at: index)
        if added > 0 { isDirty = true; statusMessage = "Wstawiono \(added) stron(y)"; bump() }
        else { statusMessage = "Nie udało się wstawić: \(url.lastPathComponent)" }
    }

    // MARK: - Źródła

    func addSourceFiles(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let ok = ext == "pdf" || ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"].contains(ext)
            if ok, !sourceFiles.contains(url) { sourceFiles.append(url) }
        }
    }

    func removeSource(_ url: URL) { sourceFiles.removeAll { $0 == url } }

    // MARK: - Podpisy

    func refreshSignatures() { signatures = store.all() }

    func importSignatureImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        try? store.add(img); refreshSignatures()
    }

    /// Zdjęcie podpisu na kartce → wycięcie tła → przezroczysty podpis w bibliotece.
    func importSignaturePhoto(_ url: URL) {
        guard let img = NSImage(contentsOf: url), let cut = SignatureProcessor.removeBackground(img) else {
            statusMessage = "Nie udało się przetworzyć zdjęcia podpisu"
            return
        }
        try? store.add(cut); refreshSignatures()
    }

    func saveDrawnSignature(paths: [NSBezierPath], size: NSSize) {
        guard !paths.isEmpty else { return }
        // Narysowany ślad jest już na przezroczystym tle — zapisujemy bez wycinania.
        let img = SignatureProcessor.image(fromPaths: paths, size: size, color: .black, lineWidth: 3)
        try? store.add(img); refreshSignatures()
    }

    /// Wklej podpis ze schowka (np. zrzut ekranu podpisu z Podglądu/strony) i wytnij tło.
    @discardableResult
    func importSignatureFromClipboard() -> Bool {
        guard let img = NSImage(pasteboard: NSPasteboard.general) else {
            statusMessage = "W schowku nie ma obrazu"
            return false
        }
        let processed = SignatureProcessor.removeBackground(img) ?? img
        try? store.add(processed); refreshSignatures()
        return true
    }

    func deleteSignature(_ url: URL) {
        store.delete(url)
        if selectedSignature == url { selectedSignature = nil }
        refreshSignatures()
    }

    // MARK: - Gesty z płótna (współrzędne strony)

    func placeSignature(onPage index: Int, at point: CGPoint) {
        guard let sigURL = selectedSignature ?? signatures.first,
              let img = store.image(sigURL),
              let page = document?.page(at: index) else { return }
        let width: CGFloat = 180
        let height = width * (img.size.height / max(1, img.size.width))
        let bounds = CGRect(x: point.x, y: point.y - height, width: width, height: height)
        PDFEditing.addSignature(image: img, to: page, bounds: bounds)
        isDirty = true; bump()
    }

    func addText(_ text: String, onPage index: Int, at point: CGPoint, fontSize: CGFloat = 16) {
        guard !text.isEmpty, let page = document?.page(at: index) else { return }
        let width = max(120, CGFloat(text.count) * fontSize * 0.6)
        let bounds = CGRect(x: point.x, y: point.y - fontSize - 6, width: width, height: fontSize + 12)
        PDFEditing.addText(text, to: page, bounds: bounds, fontSize: fontSize, color: nsInkColor)
        isDirty = true; bump()
    }

    func addWhiteout(onPage index: Int, rect: CGRect) {
        guard let page = document?.page(at: index), rect.width > 2, rect.height > 2 else { return }
        PDFEditing.addWhiteout(to: page, bounds: rect)
        isDirty = true; bump()
    }

    func addInk(onPage index: Int, path: NSBezierPath) {
        guard let page = document?.page(at: index) else { return }
        PDFEditing.addInk(paths: [path], to: page, color: nsInkColor, lineWidth: CGFloat(inkWidth))
        isDirty = true; bump()
    }

    // MARK: - Zapis

    func save() {
        guard let doc = document else { return }
        let url = documentURL ?? askSaveURL()
        guard let url else { return }
        if PDFEditing.saveFlattened(doc, to: url) {
            documentURL = url; isDirty = false; statusMessage = "Zapisano: \(url.lastPathComponent)"
        } else {
            statusMessage = "Zapis nie powiódł się"
        }
    }

    func exportAs() {
        guard let doc = document, let url = askSaveURL() else { return }
        if PDFEditing.saveFlattened(doc, to: url) {
            statusMessage = "Wyeksportowano: \(url.lastPathComponent)"
        } else {
            statusMessage = "Eksport nie powiódł się"
        }
    }

    private func askSaveURL() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentURL?.deletingPathExtension().lastPathComponent ?? "dokument") + "-podpisany.pdf"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
