import Foundation
import SkrybaKit

// MARK: - Pomocnicze

func mapFormat(_ raw: String) -> String {
    switch raw.lowercased() {
    case "md", "markdown": return "markdown"
    case "txt", "text": return "text"
    case "srt": return "srt"
    case "vtt": return "vtt"
    default: return raw
    }
}

func printUsage() {
    let text = """
    Skryba — lokalna transkrypcja audio/wideo (whisper.cpp)

    Użycie:
      skryba-cli [opcje] WEJŚCIE [WEJŚCIE...]

    WEJŚCIE: plik audio/wideo albo folder (przeszukiwany rekurencyjnie).

    Opcje:
      --out DIR          Folder docelowy na pliki wynikowe (domyślnie: ./transkrypcje)
      --model-id ID      Model z katalogu (domyślnie: large-v3-turbo). Pobierze, jeśli brak.
      --model PATH       Ścieżka do własnego pliku ggml-*.bin (pomija --model-id)
      --lang KOD         Język: auto, pl, en, ... (domyślnie: auto)
      --format FORMAT    md | txt | srt | vtt (domyślnie: md)
      --translate        Tłumacz na angielski zamiast transkrybować
      --no-gpu           Wyłącz akcelerację Metal
      --list-models      Wypisz katalog modeli i zakończ
      -h, --help         Pokaż tę pomoc
    """
    print(text)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("BŁĄD: \(message)\n".utf8))
    exit(1)
}

// MARK: - Parsowanie argumentów

var inputs: [String] = []
var outDir = "transkrypcje"
var modelID = ModelCatalog.defaultModelID
var modelPath: String? = nil
var language = "auto"
var formatRaw = "md"
var translate = false
var useGPU = true

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        printUsage(); exit(0)
    case "--list-models":
        for m in ModelCatalog.all {
            let id = m.id.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("\(id) \(m.approxSizeMB) MB  jakość \(m.stars(m.quality))  szybkość \(m.stars(m.speed))")
            print("    \(m.recommendation)")
        }
        exit(0)
    case "--out": i += 1; if i < args.count { outDir = args[i] }
    case "--model-id": i += 1; if i < args.count { modelID = args[i] }
    case "--model": i += 1; if i < args.count { modelPath = args[i] }
    case "--lang": i += 1; if i < args.count { language = args[i] }
    case "--format": i += 1; if i < args.count { formatRaw = args[i] }
    case "--translate": translate = true
    case "--no-gpu": useGPU = false
    default:
        if a.hasPrefix("--") {
            FileHandle.standardError.write(Data("Nieznana opcja: \(a)\n".utf8))
        } else {
            inputs.append(a)
        }
    }
    i += 1
}

guard !inputs.isEmpty else {
    printUsage()
    fail("podaj co najmniej jedno wejście (plik lub folder)")
}

guard let format = OutputFormat(rawValue: mapFormat(formatRaw)) else {
    fail("nieznany format: \(formatRaw) (dozwolone: md, txt, srt, vtt)")
}

// MARK: - Rozwiń wejścia

let inputURLs = inputs.map { URL(fileURLWithPath: $0) }
let files = SupportedMedia.expand(inputURLs)
guard !files.isEmpty else {
    fail("nie znaleziono obsługiwanych plików audio/wideo w podanych wejściach")
}

let outputDirectory = URL(fileURLWithPath: outDir)

// MARK: - Model

@MainActor
func resolveModelPath() async -> String {
    if let modelPath { return modelPath }
    guard let model = ModelCatalog.model(id: modelID) else {
        fail("nieznany model-id: \(modelID) (sprawdź --list-models)")
    }
    let store = ModelStore.shared
    if store.isInstalled(model) {
        return store.localURL(for: model).path
    }
    print("Pobieram model \(model.displayName) (~\(model.approxSizeMB) MB)...")
    do {
        var lastPct = -1
        let url = try await store.download(model) { p in
            let pct = Int(p * 100)
            if pct != lastPct && pct % 5 == 0 {
                lastPct = pct
                FileHandle.standardError.write(Data("\r  \(pct)%   ".utf8))
            }
        }
        FileHandle.standardError.write(Data("\r  100%\n".utf8))
        return url.path
    } catch {
        fail("nie udało się pobrać modelu: \(error.localizedDescription)")
    }
}

let resolvedModel = await resolveModelPath()

print("Model: \((resolvedModel as NSString).lastPathComponent)")
print("Język: \(language) | Format: \(format.fileExtension) | Wyjście: \(outputDirectory.path)")
print(WhisperEngine.systemInfo())
print("Plików do przetworzenia: \(files.count)\n")

let transcriber: Transcriber
do {
    transcriber = try Transcriber(modelPath: resolvedModel, language: language, useGPU: useGPU)
} catch {
    fail(error.localizedDescription)
}

// MARK: - Przetwarzanie sekwencyjne

var done = 0
var failed = 0
for (index, file) in files.enumerated() {
    let name = file.lastPathComponent
    FileHandle.standardError.write(Data("[\(index + 1)/\(files.count)] \(name)\n".utf8))
    do {
        var lastPct = -1
        let result = try await transcriber.transcribe(
            url: file,
            outputDirectory: outputDirectory,
            format: format,
            translate: translate,
            onDecodeStarted: { FileHandle.standardError.write(Data("    dekodowanie...\n".utf8)) },
            onProgress: { p in
                let pct = Int(p * 100)
                if pct != lastPct && pct % 10 == 0 {
                    lastPct = pct
                    FileHandle.standardError.write(Data("\r    \(pct)%   ".utf8))
                }
            })
        FileHandle.standardError.write(Data("\r    → \(result.outputURL.lastPathComponent)\n".utf8))
        done += 1
    } catch {
        FileHandle.standardError.write(Data("    BŁĄD: \(error.localizedDescription)\n".utf8))
        failed += 1
    }
}

print("\nGotowe: \(done)/\(files.count)" + (failed > 0 ? "  (błędy: \(failed))" : ""))

// Kończymy przez _exit, aby ominąć wadliwy statyczny destruktor ggml-metal,
// który potrafi wywołać crash przy normalnym exit(). Cała praca jest już zapisana.
fflush(stdout)
fflush(stderr)
_exit(failed > 0 && done == 0 ? 1 : 0)
