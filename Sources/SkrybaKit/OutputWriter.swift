import Foundation

/// Formaty pliku wynikowego.
public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case markdown
    case text
    case srt
    case vtt

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .text: return "txt"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .text: return "Tekst (.txt)"
        case .srt: return "Napisy SRT (.srt)"
        case .vtt: return "Napisy WebVTT (.vtt)"
        }
    }
}

/// Składa i zapisuje transkrypcję w wybranym formacie.
public enum OutputWriter {

    /// Renderuje treść pliku wynikowego.
    public static func render(
        segments: [TranscriptSegment],
        format: OutputFormat,
        sourceName: String,
        modelName: String,
        language: String
    ) -> String {
        switch format {
        case .markdown: return renderMarkdown(segments, sourceName: sourceName, modelName: modelName, language: language)
        case .text:     return renderText(segments)
        case .srt:      return renderSRT(segments)
        case .vtt:      return renderVTT(segments)
        }
    }

    /// Zapisuje transkrypcję do `directory/<stem>.<ext>` i zwraca URL pliku.
    @discardableResult
    public static func write(
        segments: [TranscriptSegment],
        to directory: URL,
        stem: String,
        format: OutputFormat,
        sourceName: String,
        modelName: String,
        language: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Unikaj cichego nadpisania pliku o tej samej nazwie (np. dwa nagrania
        // o identycznej nazwie bazowej z różnych folderów): dodaj sufiks.
        var url = directory.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }
        let content = render(
            segments: segments, format: format,
            sourceName: sourceName, modelName: modelName, language: language)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Renderery

    private static func renderMarkdown(_ segments: [TranscriptSegment], sourceName: String, modelName: String, language: String) -> String {
        var out = "# \(stripExtension(sourceName))\n\n"
        out += "> Transkrypcja nagrania: `\(sourceName)`\n"
        out += "> Model: \(modelName) (\(language))\n\n"
        let body = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        out += body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private static func renderText(_ segments: [TranscriptSegment]) -> String {
        let body = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return body.hasSuffix("\n") ? body : body + "\n"
    }

    private static func renderSRT(_ segments: [TranscriptSegment]) -> String {
        var out = ""
        var index = 1
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "\(index)\n"
            out += "\(timecode(seg.start, comma: true)) --> \(timecode(seg.end, comma: true))\n"
            out += "\(text)\n\n"
            index += 1
        }
        return out
    }

    private static func renderVTT(_ segments: [TranscriptSegment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "\(timecode(seg.start, comma: false)) --> \(timecode(seg.end, comma: false))\n"
            out += "\(text)\n\n"
        }
        return out
    }

    // MARK: - Pomocnicze

    /// Formatuje czas jako HH:MM:SS,mmm (SRT) lub HH:MM:SS.mmm (VTT).
    private static func timecode(_ seconds: TimeInterval, comma: Bool) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        let sep = comma ? "," : "."
        return String(format: "%02d:%02d:%02d\(sep)%03d", hours, minutes, secs, millis)
    }

    private static func stripExtension(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
