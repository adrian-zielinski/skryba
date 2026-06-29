import Foundation

/// Opis modelu whisper wraz z metadanymi pomagającymi w wyborze.
public struct WhisperModel: Identifiable, Sendable, Hashable {
    public let id: String          // np. "large-v3-turbo"
    public let fileName: String    // np. "ggml-large-v3-turbo.bin"
    public let displayName: String
    public let approxSizeMB: Int
    public let speed: Int          // 1 (wolny) – 5 (błyskawiczny)
    public let quality: Int        // 1 (słaba) – 5 (najlepsza)
    public let englishOnly: Bool
    public let recommendation: String

    /// Adres pobrania (Hugging Face — oficjalne repo modeli ggml whisper.cpp).
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public func stars(_ value: Int) -> String {
        String(repeating: "★", count: value) + String(repeating: "☆", count: 5 - value)
    }
}

/// Katalog dostępnych modeli + rekomendacje.
public enum ModelCatalog {

    public static let defaultModelID = "large-v3-turbo"

    public static let all: [WhisperModel] = [
        WhisperModel(
            id: "tiny", fileName: "ggml-tiny.bin", displayName: "Tiny",
            approxSizeMB: 75, speed: 5, quality: 1, englishOnly: false,
            recommendation: "Błyskawiczny szkic, krótkie notatki, słabszy sprzęt. Gubi diakrytykę i szczegóły."),
        WhisperModel(
            id: "tiny.en", fileName: "ggml-tiny.en.bin", displayName: "Tiny (tylko angielski)",
            approxSizeMB: 75, speed: 5, quality: 2, englishOnly: true,
            recommendation: "Najszybszy dla treści wyłącznie po angielsku."),
        WhisperModel(
            id: "base", fileName: "ggml-base.bin", displayName: "Base",
            approxSizeMB: 142, speed: 4, quality: 2, englishOnly: false,
            recommendation: "Szybko i akceptowalnie. Dobry do prostych nagrań."),
        WhisperModel(
            id: "base.en", fileName: "ggml-base.en.bin", displayName: "Base (tylko angielski)",
            approxSizeMB: 142, speed: 4, quality: 3, englishOnly: true,
            recommendation: "Szybki i solidny dla angielskiego."),
        WhisperModel(
            id: "small", fileName: "ggml-small.bin", displayName: "Small",
            approxSizeMB: 466, speed: 3, quality: 3, englishOnly: false,
            recommendation: "Rozsądny kompromis prędkość/jakość dla wielu języków."),
        WhisperModel(
            id: "small.en", fileName: "ggml-small.en.bin", displayName: "Small (tylko angielski)",
            approxSizeMB: 466, speed: 3, quality: 4, englishOnly: true,
            recommendation: "Bardzo dobry kompromis dla angielskiego."),
        WhisperModel(
            id: "medium", fileName: "ggml-medium.bin", displayName: "Medium",
            approxSizeMB: 1536, speed: 2, quality: 4, englishOnly: false,
            recommendation: "Wysoka jakość, wyraźnie wolniejszy. Dobry dla trudnego audio."),
        WhisperModel(
            id: "large-v3", fileName: "ggml-large-v3.bin", displayName: "Large v3",
            approxSizeMB: 3094, speed: 1, quality: 5, englishOnly: false,
            recommendation: "Maksymalna dokładność, najwolniejszy i największy. Gdy liczy się każdy szczegół."),
        WhisperModel(
            id: "large-v3-turbo", fileName: "ggml-large-v3-turbo.bin", displayName: "Large v3 Turbo",
            approxSizeMB: 1624, speed: 4, quality: 5, englishOnly: false,
            recommendation: "Domyślny i zalecany: jakość large przy prędkości small. Najlepszy do długich nagrań i języka polskiego."),
        WhisperModel(
            id: "large-v3-turbo-q5_0", fileName: "ggml-large-v3-turbo-q5_0.bin", displayName: "Large v3 Turbo (q5, lżejszy)",
            approxSizeMB: 1080, speed: 4, quality: 5, englishOnly: false,
            recommendation: "Skwantyzowany turbo — niemal ta sama jakość, mniej miejsca i RAM-u."),
    ]

    public static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    public static var defaultModel: WhisperModel {
        model(id: defaultModelID) ?? all[0]
    }
}
