import Foundation
import PDFKit

/// Most do aplikacji Apple iWork (Keynote/Numbers/Pages). Formaty .key/.numbers/.pages
/// są zamknięte — jedyną drogą jest eksport przez zainstalowaną apkę (AppleScript).
/// Odczytujemy je, eksportując do PDF i czytając tekst. Wymaga zgody na automatyzację.
enum iWorkBridge {

    /// Zwraca tekst z dokumentu iWork (przez eksport do PDF zainstalowaną apką).
    static func extractText(from url: URL, format: DocumentFormat, shouldCancel: (() -> Bool)? = nil) throws -> String {
        guard let appName = format.appleAppName else {
            throw SkrybaError.unsupportedDocument(url.lastPathComponent)
        }
        guard appInstalled(appName) else {
            throw SkrybaError.appExportFailed("aplikacja \(appName) nie jest zainstalowana")
        }
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skryba-iwork-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        try exportViaApp(appName: appName, input: url, output: pdfURL, timeout: 90, shouldCancel: shouldCancel)

        guard let doc = PDFDocument(url: pdfURL) else {
            throw SkrybaError.appExportFailed("nie udało się odczytać eksportu z \(appName)")
        }
        return doc.string ?? ""
    }

    /// Wątkowo-bezpieczny bufor na dane z potoku.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func appInstalled(_ name: String) -> Bool {
        let paths = ["/Applications/\(name).app", "/System/Applications/\(name).app"]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func exportViaApp(appName: String, input: URL, output: URL, timeout: TimeInterval, shouldCancel: (() -> Bool)?) throws {
        let script = """
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            tell application "\(appName)"
                set theDoc to open (POSIX file inPath)
                export theDoc to (POSIX file outPath) as PDF
                close theDoc saving no
            end tell
        end run
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skryba-\(UUID().uuidString).applescript")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path, input.path, output.path]

        // Drenuj oba potoki w tle, by dziecko nie zablokowało się na pełnym buforze (64 KB).
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errBox.append(d) }
        }

        try process.run()

        // Watchdog: limit czasu lub anulowanie → terminate, łaska 2 s, potem SIGKILL.
        let deadline = Date().addingTimeInterval(timeout)
        var aborted: String?
        while process.isRunning {
            if shouldCancel?() == true { aborted = "anulowano"; }
            else if Date() > deadline { aborted = "przekroczono czas — sprawdź zgodę na automatyzację \(appName) w Ustawieniach › Prywatność i bezpieczeństwo" }
            if aborted != nil {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                break
            }
            usleep(100_000)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if let aborted {
            throw SkrybaError.appExportFailed(aborted)
        }
        if process.terminationStatus != 0 {
            let msg = String(data: errBox.value, encoding: .utf8) ?? ""
            throw SkrybaError.appExportFailed(msg.isEmpty ? "kod \(process.terminationStatus)" : msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
