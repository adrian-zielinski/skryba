import Foundation

/// Zarządza lokalnymi modelami: katalog, pobieranie z postępem, usuwanie.
public final class ModelStore: @unchecked Sendable {

    public static let shared = ModelStore()
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("Skryba/Models", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func localURL(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    public func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    public func installedModels() -> [WhisperModel] {
        ModelCatalog.all.filter { isInstalled($0) }
    }

    public func delete(_ model: WhisperModel) throws {
        let url = localURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Pobiera model z postępem (0.0–1.0). Zwraca lokalny URL.
    @discardableResult
    public func download(_ model: WhisperModel, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let dest = localURL(for: model)
        if FileManager.default.fileExists(atPath: dest.path) {
            progress?(1.0)
            return dest
        }
        let downloader = ModelDownloader(progress: progress)
        let downloaded = try await downloader.download(from: model.downloadURL)

        // Walidacja: model whisper waży dziesiątki MB, nie kilobajty strony błędu.
        let attrs = try? FileManager.default.attributesOfItem(atPath: downloaded.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 1_000_000 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw SkrybaError.downloadFailed("pobrany plik jest za mały (\(size) B) — prawdopodobnie błąd serwera")
        }

        // Atomowo: najpierw do pliku .part w katalogu docelowym, potem zamiana nazwy.
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: downloaded, to: part)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: dest)
        }
        progress?(1.0)
        return dest
    }
}

/// Pobieranie dużych plików z postępem (delegat URLSession).
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let progress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var stableURL: URL?

    init(progress: ((Double) -> Void)?) {
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Nie przenoś ciała błędu (404/redirect) — didCompleteWithError zgłosi błąd.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            return
        }
        // Plik tymczasowy znika po powrocie z callbacku — przenieś od razu.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            stableURL = tmp
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            continuation?.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: SkrybaError.downloadFailed("HTTP \(http.statusCode)"))
        } else if let stableURL {
            continuation?.resume(returning: stableURL)
        } else {
            continuation?.resume(throwing: SkrybaError.downloadFailed("nie otrzymano pliku"))
        }
        continuation = nil
    }
}
