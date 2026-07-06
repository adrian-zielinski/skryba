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
      skryba-cli image --to png|jpg [opcje] OBRAZ [OBRAZ...]   (konwersja obrazów)

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

// MARK: - Podtryb: konwersja obrazów (obraz → JPG/PNG)

func printImageUsage() {
    let text = """
    Skryba — konwersja obrazów (natywnie, bez zależności)

    Użycie:
      skryba-cli image --to png|jpg [opcje] PLIK [PLIK...]

    Czyta: DNG i inne RAW-y, HEIC/HEIF, JPG, PNG, TIFF, GIF, BMP, WebP.

    Opcje:
      --to png|jpg       Format docelowy (wymagane)
      --quality N        Jakość JPG 1–100 (domyślnie: 90; PNG ignoruje)
      --beside-source    Zapisz obok oryginału (domyślne)
      --out DIR          Zapisz do wskazanego folderu
      -h, --help         Pokaż tę pomoc
    """
    print(text)
}

func runImageMode(_ args: [String]) -> Never {
    var target: DocumentFormat? = nil
    var quality = 90
    var outDir: String? = nil
    var files: [String] = []

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            printImageUsage(); exit(0)
        case "--to":
            guard i + 1 < args.count else { fail("opcja --to wymaga wartości (png|jpg)") }
            i += 1
            switch args[i].lowercased() {
            case "png": target = .png
            case "jpg", "jpeg": target = .jpg
            default: fail("nieznany format docelowy: \(args[i]) (dozwolone: png, jpg)")
            }
        case "--quality":
            guard i + 1 < args.count, let q = Int(args[i + 1]) else { fail("opcja --quality wymaga liczby 1–100") }
            i += 1; quality = max(1, min(100, q))
        case "--beside-source":
            outDir = nil
        case "--out":
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --out wymaga ścieżki") }
            i += 1; outDir = args[i]
        default:
            if a.hasPrefix("--") {
                FileHandle.standardError.write(Data("Nieznana opcja: \(a)\n".utf8))
            } else {
                files.append(a)
            }
        }
        i += 1
    }

    guard let target else { printImageUsage(); fail("podaj format docelowy: --to png|jpg") }
    guard !files.isEmpty else { printImageUsage(); fail("podaj co najmniej jeden plik obrazu") }

    var done = 0, failed = 0
    for f in files {
        // Pula per plik: przejściowe obiekty ImageIO nie kumulują się przy wsadzie wielu zdjęć.
        autoreleasepool {
            let url = URL(fileURLWithPath: f)
            let dir = outDir.map { URL(fileURLWithPath: $0) } ?? url.deletingLastPathComponent()
            do {
                let out = try ImageConverter.convert(input: url, to: target,
                                                     quality: Double(quality) / 100.0, outputDirectory: dir)
                FileHandle.standardError.write(Data("  \(url.lastPathComponent) → \(out.lastPathComponent)\n".utf8))
                done += 1
            } catch {
                FileHandle.standardError.write(Data("  BŁĄD (\(url.lastPathComponent)): \(error.localizedDescription)\n".utf8))
                failed += 1
            }
        }
    }
    let summary = "Gotowe: \(done)/\(files.count)" + (failed > 0 ? " (błędy: \(failed))" : "") + "\n"
    FileHandle.standardError.write(Data(summary.utf8))
    fflush(stdout); fflush(stderr)
    _exit(failed > 0 && done == 0 ? 1 : 0)
}

// MARK: - Podtryb: instalacja Szybkich akcji Findera

func resolveSelfPath(_ args: [String]) -> String {
    // Pozwól nadpisać ścieżkę CLI (--cli), inaczej użyj ścieżki tej binarki.
    if let i = args.firstIndex(of: "--cli"), i + 1 < args.count { return args[i + 1] }
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path { return exe }
    return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

func runInstallFinderActions(_ args: [String]) -> Never {
    let cliPath = resolveSelfPath(args)
    do {
        let urls = try FinderQuickAction.install(cliPath: cliPath)
        print("Zainstalowano Szybkie akcje Findera (CLI: \(cliPath)):")
        for u in urls { print("  \(u.path)") }
        print("Kliknij obraz prawym → Szybkie akcje.")
    } catch {
        fail("nie udało się zainstalować akcji: \(error.localizedDescription)")
    }
    fflush(stdout); fflush(stderr)
    _exit(0)
}

func runUninstallFinderActions() -> Never {
    do { try FinderQuickAction.uninstall(); print("Odinstalowano Szybkie akcje Findera.") }
    catch { fail("nie udało się odinstalować akcji: \(error.localizedDescription)") }
    fflush(stdout); fflush(stderr)
    _exit(0)
}

// Rozgałęzienie podtrybów: wychodzą przed inicjalizacją silnika whisper.
switch CommandLine.arguments.dropFirst().first {
case "image":
    runImageMode(Array(CommandLine.arguments.dropFirst(2)))
case "install-finder-actions":
    runInstallFinderActions(Array(CommandLine.arguments.dropFirst(2)))
case "uninstall-finder-actions":
    runUninstallFinderActions()
default:
    break
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
    case "--out":
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --out wymaga wartości") }
        i += 1; outDir = args[i]
    case "--model-id":
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --model-id wymaga wartości") }
        i += 1; modelID = args[i]
    case "--model":
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --model wymaga wartości") }
        i += 1; modelPath = args[i]
    case "--lang":
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --lang wymaga wartości") }
        i += 1; language = args[i]
    case "--format":
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("opcja --format wymaga wartości") }
        i += 1; formatRaw = args[i]
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
