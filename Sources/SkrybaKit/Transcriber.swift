import Foundation

/// Wynik transkrypcji pojedynczego pliku.
public struct TranscriptionResult: Sendable {
    public let outputURL: URL
    public let segments: [TranscriptSegment]
}

/// Łączy dekodowanie, silnik i zapis. Trzyma jeden wczytany silnik, więc nadaje
/// się do przetwarzania wielu plików po kolei tym samym modelem.
public final class Transcriber {

    public let engine: WhisperEngine
    public let language: String

    public init(engine: WhisperEngine, language: String = "auto") {
        self.engine = engine
        self.language = language
    }

    /// Wygodny inicjalizator ładujący model z pliku.
    public convenience init(modelPath: String, language: String = "auto", useGPU: Bool = true) throws {
        try self.init(engine: WhisperEngine(modelPath: modelPath, useGPU: useGPU), language: language)
    }

    /// Transkrybuje plik i zapisuje wynik do `outputDirectory`.
    /// - Returns: URL zapisanego pliku oraz segmenty.
    @discardableResult
    public func transcribe(
        url: URL,
        outputDirectory: URL,
        format: OutputFormat = .markdown,
        translate: Bool = false,
        onDecodeStarted: (() -> Void)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        onDecodeStarted?()
        let samples = try await AudioDecoder.decode(url: url)
        let segments = try engine.transcribe(
            samples: samples,
            language: language,
            translate: translate,
            progress: onProgress)
        let stem = url.deletingPathExtension().lastPathComponent
        let outputURL = try OutputWriter.write(
            segments: segments,
            to: outputDirectory,
            stem: stem,
            format: format,
            sourceName: url.lastPathComponent,
            modelName: engine.modelName,
            language: language)
        return TranscriptionResult(outputURL: outputURL, segments: segments)
    }
}

/// Rozszerzenia formatów obsługiwanych przez Skrybę (do filtrowania zrzucanych plików).
public enum SupportedMedia {
    public static let extensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "wma", "aiff", "aif", "caf",
        "mov", "mp4", "m4v", "webm", "mkv", "avi", "mpg", "mpeg", "3gp",
    ]

    public static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Rozwija foldery do listy obsługiwanych plików (rekurencyjnie).
    public static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let file as URL in enumerator where isSupported(file) {
                        result.append(file)
                    }
                }
            } else if isSupported(url) {
                result.append(url)
            }
        }
        return result
    }
}
