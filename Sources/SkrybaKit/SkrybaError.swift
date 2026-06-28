import Foundation

/// Błędy zgłaszane przez warstwę rdzenia Skryby.
public enum SkrybaError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case noAudioTrack(String)
    case decodeFailed(String)
    case unsupportedAudio(String)
    case transcriptionFailed(Int)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let p):
            return "Nie znaleziono modelu: \(p)"
        case .modelLoadFailed(let p):
            return "Nie udało się wczytać modelu: \(p)"
        case .noAudioTrack(let f):
            return "Plik nie zawiera ścieżki audio: \(f)"
        case .decodeFailed(let f):
            return "Nie udało się zdekodować audio: \(f)"
        case .unsupportedAudio(let f):
            return "Nieobsługiwany format (zainstaluj ffmpeg, aby obsłużyć więcej formatów): \(f)"
        case .transcriptionFailed(let code):
            return "Transkrypcja nie powiodła się (kod \(code))"
        case .downloadFailed(let m):
            return "Pobieranie nie powiodło się: \(m)"
        }
    }
}
