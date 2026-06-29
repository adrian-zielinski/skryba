import Foundation

/// Wyciąga tekst z plików Office (PPTX/XLSX) przez rozpakowanie ZIP-a i parsowanie XML.
/// Bez zależności — korzysta z systemowego `unzip`.
enum OfficeText {

    static func extractText(from url: URL, format: DocumentFormat) throws -> String {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        switch format {
        case .pptx: return try extractPPTX(dir)
        case .xlsx: return try extractXLSX(dir)
        default: throw SkrybaError.unsupportedDocument(url.lastPathComponent)
        }
    }

    // MARK: - PPTX

    private static func extractPPTX(_ dir: URL) throws -> String {
        let slidesDir = dir.appendingPathComponent("ppt/slides")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil) else {
            return ""
        }
        let slideFiles = files
            .filter { slideNumber($0) != nil }
            .sorted { (slideNumber($0) ?? 0) < (slideNumber($1) ?? 0) }

        var parts: [String] = []
        for file in slideFiles {
            guard isSafe(file, within: slidesDir), let xml = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let texts = matches(in: xml, tag: "a:t")
            let body = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                parts.append("# Slajd \(slideNumber(file) ?? 0)\n\n\(body)")
            }
        }
        // Prezentacja bez warstwy tekstowej (slajdy to obrazy) → OCR osadzonych grafik.
        if parts.isEmpty {
            let ocr = ocrEmbeddedImages(dir).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ocr.isEmpty { parts.append(ocr) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// OCR grafik osadzonych w pliku Office (ppt/media, word/media itp.).
    private static func ocrEmbeddedImages(_ dir: URL) -> String {
        let fm = FileManager.default
        guard let all = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return "" }
        let imageExt: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic"]
        let images = all
            .filter { imageExt.contains($0.pathExtension.lowercased()) && isSafe($0, within: dir) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var texts: [String] = []
        for img in images {
            guard let text = try? OCR.recognizeImageFile(img) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
        }
        return texts.joined(separator: "\n\n")
    }

    /// Numer slajdu z nazwy `slideN.xml` (tylko ten wzorzec).
    private static func slideNumber(_ url: URL) -> Int? {
        let name = url.lastPathComponent.lowercased()
        guard name.hasPrefix("slide"), name.hasSuffix(".xml") else { return nil }
        let digits = name.dropFirst("slide".count).dropLast(".xml".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    // MARK: - XLSX

    private static func extractXLSX(_ dir: URL) throws -> String {
        // Najwięcej tekstu siedzi w sharedStrings; dla prostego zrzutu to wystarcza.
        let shared = dir.appendingPathComponent("xl/sharedStrings.xml")
        if isSafe(shared, within: dir), let xml = try? String(contentsOf: shared, encoding: .utf8) {
            // Pomiń przewodniki fonetyczne (<rPh>…</rPh>), które nie są treścią komórek.
            let cleaned = stripTags(xml, tag: "rPh")
            let texts = matches(in: cleaned, tag: "t")
            return texts.joined(separator: "\n")
        }
        // Fallback: inline strings w arkuszach.
        let sheetsDir = dir.appendingPathComponent("xl/worksheets")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sheetsDir, includingPropertiesForKeys: nil) else { return "" }
        var texts: [String] = []
        for file in files where file.pathExtension.lowercased() == "xml" {
            if isSafe(file, within: sheetsDir), let xml = try? String(contentsOf: file, encoding: .utf8) {
                texts.append(contentsOf: matches(in: stripTags(xml, tag: "rPh"), tag: "t"))
            }
        }
        return texts.joined(separator: "\n")
    }

    // MARK: - Pomocnicze

    /// Wyciąga zawartość wszystkich elementów `<tag ...>...</tag>` i odkodowuje encje XML.
    private static func matches(in xml: String, tag: String) -> [String] {
        let pattern = "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        var results: [String] = []
        for m in regex.matches(in: xml, range: range) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let decoded = unescapeXML(String(xml[r]))
            if !decoded.isEmpty { results.append(decoded) }
        }
        return results
    }

    /// Usuwa całe elementy `<tag…>…</tag>` (np. przewodniki fonetyczne <rPh>).
    private static func stripTags(_ xml: String, tag: String) -> String {
        let pattern = "<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return xml }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.stringByReplacingMatches(in: xml, range: range, withTemplate: "")
    }

    /// Zabezpieczenie przed dowiązaniami/wyjściem poza katalog tymczasowy.
    private static func isSafe(_ url: URL, within base: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(root)
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func unzip(_ url: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", url.path, "-d", dest.path]
        let err = Pipe(); process.standardError = err; process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SkrybaError.documentReadFailed(url.lastPathComponent)
        }
        return dest
    }
}
