import Foundation
import SkrybaKit

// Lekki harness testowy (działa wszędzie, nie wymaga XCTest ani Xcode).

final class Runner {
    var passed = 0
    var failed = 0
    var skipped = 0

    func suite(_ name: String) { print("\n▸ \(name)") }

    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1; print("  ✓ \(message)") }
        else { failed += 1; print("  ✗ \(message)") }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        check(a == b, "\(message)  [\(a) == \(b)]")
    }

    func skip(_ message: String) { skipped += 1; print("  ⤼ POMINIĘTO: \(message)") }

    func finish() -> Never {
        print("\n— Wynik: \(passed) zaliczonych, \(failed) niezaliczonych, \(skipped) pominiętych —")
        fflush(stdout)
        // _exit omija wadliwy statyczny destruktor ggml-metal przy zamknięciu.
        _exit(failed == 0 ? 0 : 1)
    }
}

let t = Runner()

// MARK: - OutputWriter

let segments = [
    TranscriptSegment(text: " Pierwsze zdanie.", start: 0.0, end: 1.5),
    TranscriptSegment(text: "Drugie zdanie.", start: 1.5, end: 3.25),
    TranscriptSegment(text: "   ", start: 3.25, end: 3.3),
]

t.suite("OutputWriter")
let md = OutputWriter.render(segments: segments, format: .markdown,
                             sourceName: "nagranie.m4a", modelName: "ggml-test.bin", language: "pl")
t.check(md.contains("# nagranie"), "Markdown ma nagłówek z nazwą")
t.check(md.contains("> Transkrypcja nagrania: `nagranie.m4a`"), "Markdown ma wiersz źródła")
t.check(md.contains("> Model: ggml-test.bin (pl)"), "Markdown ma wiersz modelu")
t.check(md.contains("Pierwsze zdanie.") && md.contains("Drugie zdanie."), "Markdown ma treść")

let txt = OutputWriter.render(segments: segments, format: .text,
                              sourceName: "x.wav", modelName: "m", language: "pl")
t.check(!txt.contains("#"), "Tekst nie ma nagłówka Markdown")
t.check(txt.contains("Pierwsze zdanie."), "Tekst ma treść")

let srt = OutputWriter.render(segments: segments, format: .srt,
                              sourceName: "x", modelName: "m", language: "pl")
t.check(srt.contains("1\n00:00:00,000 --> 00:00:01,500"), "SRT: numeracja i znaczniki z przecinkiem")
t.check(srt.contains("2\n00:00:01,500 --> 00:00:03,250"), "SRT: drugi segment")

let vtt = OutputWriter.render(segments: segments, format: .vtt,
                              sourceName: "x", modelName: "m", language: "pl")
t.check(vtt.hasPrefix("WEBVTT"), "VTT: nagłówek WEBVTT")
t.check(vtt.contains("00:00:01.500 --> 00:00:03.250"), "VTT: znaczniki z kropką")

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try OutputWriter.write(segments: segments, to: dir, stem: "moje nagranie",
                                     format: .markdown, sourceName: "moje nagranie.mov",
                                     modelName: "ggml-test.bin", language: "auto")
    t.equal(url.lastPathComponent, "moje nagranie.md", "Zapis: poprawna nazwa i rozszerzenie")
    let content = try String(contentsOf: url, encoding: .utf8)
    t.check(content.contains("Pierwsze zdanie."), "Zapis: treść w pliku")
} catch {
    t.check(false, "Zapis pliku rzucił błąd: \(error)")
}

// MARK: - ModelCatalog

t.suite("ModelCatalog")
t.check(ModelCatalog.model(id: ModelCatalog.defaultModelID) != nil, "Domyślny model istnieje")
t.equal(ModelCatalog.defaultModelID, "large-v3-turbo", "Domyślny to large-v3-turbo")
let ids = ModelCatalog.all.map(\.id)
t.equal(ids.count, Set(ids).count, "Identyfikatory są unikalne")
t.check(ModelCatalog.all.allSatisfy { $0.downloadURL.scheme == "https" }, "Wszystkie URL-e to https")
t.check(ModelCatalog.all.allSatisfy { (1...5).contains($0.quality) && (1...5).contains($0.speed) }, "Jakość/szybkość w zakresie 1–5")
t.check(ModelCatalog.all.allSatisfy { $0.approxSizeMB > 0 && !$0.recommendation.isEmpty }, "Rozmiar > 0 i jest rekomendacja")
t.equal(ModelCatalog.defaultModel.stars(5), "★★★★★", "Gwiazdki: 5/5")
t.equal(ModelCatalog.defaultModel.stars(3), "★★★☆☆", "Gwiazdki: 3/5")

// MARK: - SupportedMedia

t.suite("SupportedMedia")
t.check(SupportedMedia.isSupported(URL(fileURLWithPath: "a/b.m4a")), "m4a obsługiwane")
t.check(SupportedMedia.isSupported(URL(fileURLWithPath: "a/b.MP4")), "MP4 (wielkość liter) obsługiwane")
t.check(!SupportedMedia.isSupported(URL(fileURLWithPath: "a/b.txt")), "txt nieobsługiwane")
do {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("skryba-expand-\(UUID().uuidString)")
    let sub = dir.appendingPathComponent("podfolder")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("a.m4a"))
    try Data().write(to: dir.appendingPathComponent("notatka.txt"))
    try Data().write(to: sub.appendingPathComponent("b.mp3"))
    let found = Set(SupportedMedia.expand([dir]).map(\.lastPathComponent))
    t.check(found.contains("a.m4a") && found.contains("b.mp3"), "Rozwijanie folderu (też podfolder)")
    t.check(!found.contains("notatka.txt"), "Rozwijanie pomija nieobsługiwane")
    t.equal(found.count, 2, "Rozwijanie: dokładnie 2 pliki")
} catch {
    t.check(false, "Rozwijanie folderu rzuciło błąd: \(error)")
}

// MARK: - AudioDecoder (wymaga `say`)

t.suite("AudioDecoder")
func makeSpeech(_ text: String, ext: String = "aiff") -> URL? {
    let say = "/usr/bin/say"
    guard FileManager.default.isExecutableFile(atPath: say) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-say-\(UUID().uuidString).\(ext)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: say)
    p.arguments = ["-o", url.path, text]
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    return p.terminationStatus == 0 ? url : nil
}

if let speech = makeSpeech("This is a short audio decoding test for Skryba.") {
    defer { try? FileManager.default.removeItem(at: speech) }
    do {
        let samples = try await AudioDecoder.decode(url: speech)
        t.check(samples.count > 8_000, "Dekodowanie zwraca dość próbek (\(samples.count))")
        t.check(samples.contains { abs($0) > 0.001 }, "Próbki zawierają sygnał (nie cisza)")
        let dur = Double(samples.count) / AudioDecoder.targetSampleRate
        t.check((0.5...20.0).contains(dur), "Sensowny czas trwania: \(String(format: "%.2f", dur)) s")
    } catch {
        t.check(false, "Dekodowanie rzuciło błąd: \(error)")
    }
} else {
    t.skip("brak `say` — test dekodowania")
}

// niepoprawny plik → błąd
do {
    let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-bogus-\(UUID().uuidString).m4a")
    try Data([0,1,2,3]).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }
    do {
        _ = try await AudioDecoder.decode(url: bogus)
        t.check(false, "Niepoprawny plik powinien rzucić błąd")
    } catch {
        t.check(true, "Niepoprawny plik rzuca błąd zgodnie z oczekiwaniem")
    }
} catch {
    t.check(false, "Nie udało się przygotować pliku testowego: \(error)")
}

// MARK: - End-to-end (silnik whisper) — gdy podano SKRYBA_E2E_MODEL

t.suite("End-to-end (silnik)")
if let modelPath = ProcessInfo.processInfo.environment["SKRYBA_E2E_MODEL"],
   FileManager.default.fileExists(atPath: modelPath) {
    if let audio = makeSpeech("The quick brown fox jumps over the lazy dog.") {
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            let engine = try WhisperEngine(modelPath: modelPath)
            let samples = try await AudioDecoder.decode(url: audio)
            let segs = try engine.transcribe(samples: samples, language: "en")
            let text = segs.map(\.text).joined(separator: " ").lowercased()
            t.check(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Transkrypcja niepusta")
            let expected = ["fox", "dog", "quick", "brown", "lazy", "jump"]
            t.check(expected.contains { text.contains($0) }, "Rozpoznano oczekiwane słowo (\(text.prefix(60))...)")
        } catch {
            t.check(false, "Silnik rzucił błąd: \(error)")
        }
    } else {
        t.skip("brak `say` — test silnika")
    }
} else {
    t.skip("brak SKRYBA_E2E_MODEL — ustaw ścieżkę do ggml-*.bin, by uruchomić test silnika")
}

t.finish()
