import Foundation
import AppKit

/// Biblioteka podpisów użytkownika (PNG-i w Application Support/Skryba/Signatures).
public final class SignatureStore: @unchecked Sendable {

    public static let shared = SignatureStore()
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("Skryba/Signatures", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Zapisuje podpis jako PNG i zwraca jego URL.
    @discardableResult
    public func add(_ image: NSImage) throws -> URL {
        guard let data = SignatureProcessor.pngData(image) else {
            throw SkrybaError.documentReadFailed("podpis")
        }
        let url = directory.appendingPathComponent("podpis-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    /// Wszystkie zapisane podpisy (najnowsze pierwsze).
    public func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    public func image(_ url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    public func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
