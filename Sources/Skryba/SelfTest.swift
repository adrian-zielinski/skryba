import Foundation
import SkrybaKit

/// Headless test pełnej ścieżki: model → dekodowanie → transkrypcja → zapis.
/// Użycie: skryba --selftest --model PATH --input AUDIO [--out DIR] [--lang KOD]
enum SelfTest {
    static func runAndExit() -> Never {
        var model: String?
        var input: String?
        var out = NSTemporaryDirectory() + "skryba-selftest"
        var lang = "auto"

        let args = CommandLine.arguments
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model": i += 1; if i < args.count { model = args[i] }
            case "--input": i += 1; if i < args.count { input = args[i] }
            case "--out": i += 1; if i < args.count { out = args[i] }
            case "--lang": i += 1; if i < args.count { lang = args[i] }
            default: break
            }
            i += 1
        }

        guard let model, let input else {
            FileHandle.standardError.write(Data("selftest wymaga --model i --input\n".utf8))
            _exit(2)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        Task {
            do {
                let transcriber = try Transcriber(modelPath: model, language: lang)
                let result = try await transcriber.transcribe(
                    url: URL(fileURLWithPath: input),
                    outputDirectory: URL(fileURLWithPath: out),
                    format: .markdown)
                let text = (try? String(contentsOf: result.outputURL, encoding: .utf8)) ?? ""
                success = text.count > 20
                print("SELFTEST: \(result.outputURL.path) (\(text.count) znaków, \(result.segments.count) segmentów)")
            } catch {
                FileHandle.standardError.write(Data("SELFTEST błąd: \(error.localizedDescription)\n".utf8))
            }
            semaphore.signal()
        }
        semaphore.wait()
        fflush(stdout)
        fflush(stderr)
        _exit(success ? 0 : 1)
    }
}
