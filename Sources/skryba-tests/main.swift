import Foundation
import AppKit
import PDFKit
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

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-collision-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let u1 = try OutputWriter.write(segments: segments, to: dir, stem: "kolizja",
                                    format: .markdown, sourceName: "a.m4a", modelName: "m", language: "pl")
    let u2 = try OutputWriter.write(segments: segments, to: dir, stem: "kolizja",
                                    format: .markdown, sourceName: "b.m4a", modelName: "m", language: "pl")
    t.equal(u1.lastPathComponent, "kolizja.md", "Kolizja: pierwszy bez sufiksu")
    t.equal(u2.lastPathComponent, "kolizja-2.md", "Kolizja: drugi z sufiksem -2 (brak nadpisania)")
    let both = FileManager.default.fileExists(atPath: u1.path) && FileManager.default.fileExists(atPath: u2.path)
    t.check(both, "Kolizja: oba pliki istnieją")
} catch {
    t.check(false, "Test kolizji rzucił błąd: \(error)")
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

            // Regresja: język "auto" MUSI transkrybować (nie tylko wykrywać język).
            let autoSegs = try engine.transcribe(samples: samples, language: "auto")
            let autoText = autoSegs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            t.check(!autoText.isEmpty, "Język 'auto' transkrybuje (nie zwraca pustego wyniku)")

            // Anulowanie: shouldCancel == true ma przerwać i rzucić .cancelled.
            do {
                _ = try engine.transcribe(samples: samples, language: "en", shouldCancel: { true })
                t.check(false, "Anulowanie powinno rzucić .cancelled")
            } catch SkrybaError.cancelled {
                t.check(true, "Anulowanie przerywa transkrypcję (.cancelled)")
            } catch {
                t.check(false, "Anulowanie rzuciło inny błąd: \(error)")
            }
        } catch {
            t.check(false, "Silnik rzucił błąd: \(error)")
        }
    } else {
        t.skip("brak `say` — test silnika")
    }
} else {
    t.skip("brak SKRYBA_E2E_MODEL — ustaw ścieżkę do ggml-*.bin, by uruchomić test silnika")
}

// MARK: - Konwersja dokumentów

t.suite("Konwersja dokumentów")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-conv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let mdURL = dir.appendingPathComponent("notatka.md")
    try "# Tytuł testowy\n\nAkapit z **pogrubieniem** i *kursywą*.\n\n- punkt jeden\n- punkt dwa\n"
        .write(to: mdURL, atomically: true, encoding: .utf8)

    // md → docx → txt (treść zachowana)
    let docxURL = try await DocumentConverter.convert(input: mdURL, to: .docx, outputDirectory: dir)
    t.check(FileManager.default.fileExists(atPath: docxURL.path), "md→docx: plik powstał")
    let txtURL = try await DocumentConverter.convert(input: docxURL, to: .txt, outputDirectory: dir)
    let txt = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
    t.check(txt.contains("Tytuł testowy") && txt.contains("pogrubieniem"), "docx→txt: treść zachowana")

    // md → pdf (PDFKit czyta tekst)
    let pdfURL = try await DocumentConverter.convert(input: mdURL, to: .pdf, outputDirectory: dir)
    let pdfText = PDFDocument(url: pdfURL)?.string ?? ""
    t.check(pdfText.contains("Tytuł testowy"), "md→pdf: tekst obecny w PDF")

    // md → html
    let htmlURL = try await DocumentConverter.convert(input: mdURL, to: .html, outputDirectory: dir)
    let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
    t.check(html.contains("Tytuł testowy"), "md→html: treść zachowana")

    // md → rtf → md (round trip treści)
    let rtfURL = try await DocumentConverter.convert(input: mdURL, to: .rtf, outputDirectory: dir)
    let backMd = try await DocumentConverter.convert(input: rtfURL, to: .md, outputDirectory: dir)
    let backText = (try? String(contentsOf: backMd, encoding: .utf8)) ?? ""
    t.check(backText.contains("Tytuł testowy"), "rtf→md: treść zachowana")

    // cele dla md
    let targets = DocumentFormat.targets(for: .md, includeAppleApps: false).map(\.rawValue)
    t.check(!targets.contains("md") && targets.contains("docx") && targets.contains("pdf"),
            "Cele md: bez samego md, z docx i pdf")
    t.check(!targets.contains("pptx") && !targets.contains("key"),
            "Cele: brak zapisu do pptx/iWork (tylko odczyt)")

    // Regresja: konwersja MUSI działać wywołana spoza głównego wątku
    // (importery NSAttributedString HTML/DOCX wymagają main — sprawdzamy skok na MainActor).
    let offMain = try await Task.detached {
        try await DocumentConverter.convert(input: mdURL, to: .docx, outputDirectory: dir)
    }.value
    t.check(FileManager.default.fileExists(atPath: offMain.path), "md→docx z wątku tła (off-main) działa")
}
catch { t.check(false, "Konwersja dokumentów rzuciła błąd: \(error)") }

// Ekstrakcja tekstu z PPTX/XLSX (fabrykujemy minimalne pliki przez `zip`)
func makeZip(_ root: URL, output: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.arguments = ["-q", "-r", output.path, "."]
    p.currentDirectoryURL = root
    do { try p.run(); p.waitUntilExit() } catch { return false }
    return p.terminationStatus == 0
}

do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-office-\(UUID().uuidString)")
    let slides = base.appendingPathComponent("src/ppt/slides")
    try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
    try "<?xml version=\"1.0\"?><p:sld xmlns:a=\"x\"><a:t>Witaj na slajdzie</a:t><a:t>Druga linia</a:t></p:sld>"
        .write(to: slides.appendingPathComponent("slide1.xml"), atomically: true, encoding: .utf8)
    let pptx = base.appendingPathComponent("test.pptx")
    defer { try? FileManager.default.removeItem(at: base) }
    if makeZip(base.appendingPathComponent("src"), output: pptx) {
        let out = try await DocumentConverter.convert(input: pptx, to: .md, outputDirectory: base)
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        t.check(text.contains("Witaj na slajdzie") && text.contains("Druga linia"), "pptx→md: wyciągnięto tekst slajdu")
    } else { t.skip("brak `zip` — test pptx") }
}
catch { t.check(false, "Test pptx rzucił błąd: \(error)") }

do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-xlsx-\(UUID().uuidString)")
    let xl = base.appendingPathComponent("src/xl")
    try FileManager.default.createDirectory(at: xl, withIntermediateDirectories: true)
    try "<?xml version=\"1.0\"?><sst><si><t>Komórka A</t></si><si><t>Komórka B</t></si></sst>"
        .write(to: xl.appendingPathComponent("sharedStrings.xml"), atomically: true, encoding: .utf8)
    let xlsx = base.appendingPathComponent("test.xlsx")
    defer { try? FileManager.default.removeItem(at: base) }
    if makeZip(base.appendingPathComponent("src"), output: xlsx) {
        let out = try await DocumentConverter.convert(input: xlsx, to: .txt, outputDirectory: base)
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        t.check(text.contains("Komórka A") && text.contains("Komórka B"), "xlsx→txt: wyciągnięto komórki")
    } else { t.skip("brak `zip` — test xlsx") }
}
catch { t.check(false, "Test xlsx rzucił błąd: \(error)") }

// MARK: - OCR (obrazy / skany)

t.suite("OCR obrazów i skanów")

func makeTextPNG(_ text: String, to url: URL) -> Bool {
    let size = NSSize(width: 720, height: 180)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 24, y: 72),
        withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
    img.unlockFocus()
    var r = NSRect(origin: .zero, size: size)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return false }
    guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: url)) != nil
}

do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-ocr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let png = base.appendingPathComponent("skan.png")
    guard makeTextPNG("Konwersja OCR dziala", to: png) else {
        t.skip("nie udało się wygenerować obrazu testowego"); throw CancellationError()
    }

    // .image → txt (OCR)
    let imgTargets = DocumentFormat.targets(for: .image, includeAppleApps: false).map(\.rawValue)
    t.check(imgTargets.contains("txt") && imgTargets.contains("md"), "Obraz: cele zawierają txt i md")

    let outTxt = try await DocumentConverter.convert(input: png, to: .txt, outputDirectory: base)
    let ocrText = ((try? String(contentsOf: outTxt, encoding: .utf8)) ?? "").lowercased()
    t.check(ocrText.contains("ocr") || ocrText.contains("konwersja"),
            "png→txt (OCR): rozpoznano tekst [\(ocrText.prefix(40))]")

    // skan PDF (strona-obraz, bez warstwy tekstowej) → OCR
    let scanPDF = base.appendingPathComponent("skan.pdf")
    if let nsimg = NSImage(contentsOf: png), let page = PDFPage(image: nsimg) {
        let doc = PDFDocument(); doc.insert(page, at: 0); doc.write(to: scanPDF)
        let outPdfTxt = try await DocumentConverter.convert(input: scanPDF, to: .txt, outputDirectory: base)
        let pdfOcr = ((try? String(contentsOf: outPdfTxt, encoding: .utf8)) ?? "").lowercased()
        t.check(pdfOcr.contains("ocr") || pdfOcr.contains("konwersja"),
                "skan PDF→txt (OCR): rozpoznano tekst [\(pdfOcr.prefix(40))]")
    } else {
        t.skip("nie udało się zbudować PDF-skanu")
    }
}
catch is CancellationError {}
catch { t.check(false, "Test OCR rzucił błąd: \(error)") }

t.finish()
