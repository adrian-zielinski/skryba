import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
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

// MARK: - Konwersja obrazów (JPG/PNG)

t.suite("Konwersja obrazów")

func imageUTI(_ url: URL) -> String? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceGetType(src) as String?
}
func imagePixelSize(_ url: URL) -> (w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
func topLeftPixel(_ url: URL) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (px[0], px[1], px[2], px[3])
}
func writePNG(_ cg: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cg, nil)
    return CGImageDestinationFinalize(dest)
}
func makeTransparentPNG(to url: URL) -> Bool {
    let w = 100, h = 100
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))           // tło całkowicie przezroczyste
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 40))        // nieprzezroczysty czerwony kwadrat
    guard let cg = ctx.makeImage() else { return false }
    return writePNG(cg, to: url)
}
func makeNoisePNG(to url: URL, size: Int = 256) -> Bool {
    let w = size, h = size
    var px = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt64 = 0x9E3779B97F4A7C15                        // deterministyczny LCG (test bez losowości)
    func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8((seed >> 33) & 0xFF) }
    for i in 0..<(w * h) { px[i*4] = next(); px[i*4+1] = next(); px[i*4+2] = next(); px[i*4+3] = 255 }
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let cg = ctx.makeImage() else { return false }
    return writePNG(cg, to: url)
}
func makeOrientedJPEG(to url: URL, w: Int, h: Int, orientation: Int) -> Bool {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    guard let cg = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}
func fileSize(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? Int) ?? 0
}

// Cele: obraz oferuje png/jpg (i wciąż OCR-owy txt); tekst nie oferuje celów obrazowych.
let imgTargetsRaw = DocumentFormat.targets(for: .image, includeAppleApps: false).map(\.rawValue)
t.check(imgTargetsRaw.contains("png") && imgTargetsRaw.contains("jpg"), "Obraz: cele zawierają png i jpg")
t.check(imgTargetsRaw.contains("txt"), "Obraz: nadal jest cel txt (OCR)")
let mdTargetsRaw = DocumentFormat.targets(for: .md, includeAppleApps: false).map(\.rawValue)
t.check(!mdTargetsRaw.contains("png") && !mdTargetsRaw.contains("jpg"), "Tekst (md): brak celów obrazowych")

// PNG → JPG i JPG → PNG: typ i wymiary.
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let png = base.appendingPathComponent("foto.png")
    guard makeTextPNG("Zdjecie testowe", to: png) else { t.skip("nie wygenerowano PNG"); throw CancellationError() }

    let jpg = try await DocumentConverter.convert(input: png, to: .jpg, outputDirectory: base)
    t.equal(jpg.pathExtension, "jpg", "PNG→JPG: rozszerzenie .jpg")
    t.equal(imageUTI(jpg), "public.jpeg", "PNG→JPG: wynik to JPEG")
    let srcSize = imagePixelSize(png), outSize = imagePixelSize(jpg)
    t.check(srcSize != nil && outSize != nil && srcSize! == outSize!,
            "PNG→JPG: wymiary zachowane [źródło \(String(describing: srcSize)) → wynik \(String(describing: outSize))]")

    let png2 = try await DocumentConverter.convert(input: jpg, to: .png, outputDirectory: base)
    t.equal(imageUTI(png2), "public.png", "JPG→PNG: wynik to PNG")
}
catch is CancellationError {}
catch { t.check(false, "Test PNG↔JPG rzucił błąd: \(error)") }

// PNG z przezroczystością → JPG: tło spłaszczone na biel, brak alfy.
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-alpha-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let png = base.appendingPathComponent("przezr.png")
    guard makeTransparentPNG(to: png) else { t.skip("nie wygenerowano PNG z alfą"); throw CancellationError() }
    let jpg = try ImageConverter.convert(input: png, to: .jpg, quality: 0.9, outputDirectory: base)
    if let c = topLeftPixel(jpg) {
        t.check(c.r > 240 && c.g > 240 && c.b > 240, "PNG(alfa)→JPG: przezroczyste tło stało się białe [\(c)]")
        t.check(c.a == 255, "PNG(alfa)→JPG: wynik nieprzezroczysty")
    } else { t.check(false, "nie odczytano piksela wyniku") }
}
catch is CancellationError {}
catch { t.check(false, "Test przezroczystości rzucił błąd: \(error)") }

// Jakość JPG respektowana: niższa jakość → mniejszy plik.
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-q-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("szum.png")
    guard makeNoisePNG(to: src) else { t.skip("nie wygenerowano obrazu szumu"); throw CancellationError() }
    let low = try ImageConverter.convert(input: src, to: .jpg, quality: 0.1, outputDirectory: base)
    let high = try ImageConverter.convert(input: src, to: .jpg, quality: 0.95, outputDirectory: base)
    t.check(fileSize(high) > fileSize(low), "Jakość JPG: 95% > 10% rozmiaru [\(fileSize(low)) < \(fileSize(high))]")
}
catch is CancellationError {}
catch { t.check(false, "Test jakości JPG rzucił błąd: \(error)") }

// Orientacja EXIF wypalana: JPEG 100×40 z orientacją 6 → obraz pionowy 40×100.
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-ori-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let oriented = base.appendingPathComponent("obrocony.jpg")
    guard makeOrientedJPEG(to: oriented, w: 100, h: 40, orientation: 6) else { t.skip("nie wygenerowano JPEG z orientacją"); throw CancellationError() }
    let out = try ImageConverter.convert(input: oriented, to: .png, quality: 0.9, outputDirectory: base)
    let sz = imagePixelSize(out)
    t.check(sz.map { $0.w == 40 && $0.h == 100 } ?? false,
            "Orientacja: 100×40 (orient 6) → wypalone 40×100 [\(String(describing: sz))]")
}
catch is CancellationError {}
catch { t.check(false, "Test orientacji rzucił błąd: \(error)") }

// Szeroki gamut (Display P3) zachowany przy wypalaniu orientacji — nie klamrujemy do sRGB.
func imageColorSpaceName(_ url: URL) -> String? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let cs = cg.colorSpace, let name = cs.name else { return nil }
    return name as String
}
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-p3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { t.skip("brak przestrzeni P3"); throw CancellationError() }
    let w = 100, h = 40
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let redP3 = CGColor(colorSpace: p3, components: [1, 0, 0, 1]) else {
        t.skip("nie zbudowano kontekstu P3"); throw CancellationError()
    }
    ctx.setFillColor(redP3)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let src = base.appendingPathComponent("p3.jpg")
    guard let cg = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        t.skip("nie zapisano źródła P3"); throw CancellationError()
    }
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)   // wymusza gałąź oriented()
    _ = CGImageDestinationFinalize(dest)

    // Oba cele muszą zachować P3. JPG to realna ścieżka (spłaszczanie alfy nie może zrzucić gamutu).
    let outJpg = try ImageConverter.convert(input: src, to: .jpg, quality: 0.9, outputDirectory: base)
    let outPng = try ImageConverter.convert(input: src, to: .png, quality: 0.9, outputDirectory: base)
    let jpgName = imageColorSpaceName(outJpg), pngName = imageColorSpaceName(outPng)
    t.check(jpgName?.contains("P3") ?? false,
            "Szeroki gamut (JPG): profil P3 zachowany przy obrocie [\(String(describing: jpgName))]")
    t.check(pngName?.contains("P3") ?? false,
            "Szeroki gamut (PNG): profil P3 zachowany przy obrocie [\(String(describing: pngName))]")
}
catch is CancellationError {}
catch { t.check(false, "Test gamutu P3 rzucił błąd: \(error)") }

// P3 z KANAŁEM ALFA → JPG: spłaszczanie na biel musi zachować gamut (nie zrzucać do sRGB).
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-p3a-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { t.skip("brak P3"); throw CancellationError() }
    let w = 80, h = 80
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let redP3 = CGColor(colorSpace: p3, components: [1, 0, 0, 1]) else {
        t.skip("nie zbudowano kontekstu P3+alfa"); throw CancellationError()
    }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))                 // tło przezroczyste
    ctx.setFillColor(redP3)
    ctx.fill(CGRect(x: 20, y: 20, width: 40, height: 40))             // nasycony czerwony kwadrat P3
    let src = base.appendingPathComponent("p3alpha.png")
    guard let cg = ctx.makeImage(), writePNG(cg, to: src) else { t.skip("nie zapisano P3+alfa"); throw CancellationError() }

    let out = try ImageConverter.convert(input: src, to: .jpg, quality: 0.9, outputDirectory: base)
    let name = imageColorSpaceName(out)
    t.check(name?.contains("P3") ?? false,
            "P3 z alfą → JPG: gamut zachowany po spłaszczeniu (nie sRGB) [\(String(describing: name))]")
    if let c = topLeftPixel(out) {
        t.check(c.a == 255, "P3 z alfą → JPG: wynik nieprzezroczysty")
    }
}
catch is CancellationError {}
catch { t.check(false, "Test P3+alfa rzucił błąd: \(error)") }

// Kolizja nazw: druga konwersja tego samego celu → sufiks -2 (bez nadpisania).
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-col-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let png = base.appendingPathComponent("kadr.png")
    guard makeTextPNG("Kadr", to: png) else { t.skip("nie wygenerowano PNG"); throw CancellationError() }
    let a = try ImageConverter.convert(input: png, to: .jpg, quality: 0.9, outputDirectory: base)
    let b = try ImageConverter.convert(input: png, to: .jpg, quality: 0.9, outputDirectory: base)
    t.equal(a.lastPathComponent, "kadr.jpg", "Kolizja: pierwszy bez sufiksu")
    t.equal(b.lastPathComponent, "kadr-2.jpg", "Kolizja: drugi z sufiksem -2")
    t.check(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path),
            "Kolizja: oba pliki istnieją")
}
catch is CancellationError {}
catch { t.check(false, "Test kolizji obrazów rzucił błąd: \(error)") }

// Opcjonalny E2E na realnym pliku (np. DNG): SKRYBA_IMG_TEST=ścieżka
if let imgPath = ProcessInfo.processInfo.environment["SKRYBA_IMG_TEST"],
   FileManager.default.fileExists(atPath: imgPath) {
    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-img-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let out = try ImageConverter.convert(input: URL(fileURLWithPath: imgPath), to: .jpg, quality: 0.9, outputDirectory: base)
        t.equal(imageUTI(out), "public.jpeg", "E2E: realny obraz → JPEG")
        t.check((imagePixelSize(out)?.w ?? 0) > 0, "E2E: wynik ma wymiary [\(String(describing: imagePixelSize(out)))]")
        let srcName = imageColorSpaceName(URL(fileURLWithPath: imgPath))
        let outName = imageColorSpaceName(out)
        t.check(srcName == nil || outName == srcName,
                "E2E: profil koloru zachowany [źródło \(String(describing: srcName)) → wynik \(String(describing: outName))]")
    } catch {
        t.check(false, "E2E obrazu rzucił błąd: \(error)")
    }
} else {
    t.skip("ustaw SKRYBA_IMG_TEST=ścieżka/do/obrazu (np. DNG), aby przetestować realny plik")
}

// MARK: - Szybkie akcje Findera (instalator)

t.suite("Akcje Findera")
do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-svc-\(UUID().uuidString)")
    let services = base.appendingPathComponent("Services")
    defer { try? FileManager.default.removeItem(at: base) }
    let cli = "/Applications/Skryba.app/Contents/MacOS/skryba-cli"

    let installed = try FinderQuickAction.install(cliPath: cli, to: services)
    t.equal(installed.count, 2, "Instalacja: powstały dwa bundle")

    let jpgDir = services.appendingPathComponent("Konwertuj na JPG (Skryba).workflow/Contents")
    let pngDir = services.appendingPathComponent("Konwertuj na PNG (Skryba).workflow/Contents")
    let jpgWflow = jpgDir.appendingPathComponent("document.wflow")
    let jpgInfo = jpgDir.appendingPathComponent("Info.plist")
    let pngWflow = pngDir.appendingPathComponent("document.wflow")

    t.check(FileManager.default.fileExists(atPath: jpgWflow.path), "JPG: document.wflow istnieje")
    t.check(FileManager.default.fileExists(atPath: jpgInfo.path), "JPG: Info.plist istnieje")

    // Poprawność plistów (łapie błędy escapowania XML).
    func isValidPlist(_ url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url) else { return false }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) != nil
    }
    t.check(isValidPlist(jpgWflow), "JPG: document.wflow to poprawny plist")
    t.check(isValidPlist(jpgInfo), "JPG: Info.plist to poprawny plist")
    t.check(isValidPlist(pngWflow), "PNG: document.wflow to poprawny plist")

    let jpgScript = (try? String(contentsOf: jpgWflow, encoding: .utf8)) ?? ""
    let pngScript = (try? String(contentsOf: pngWflow, encoding: .utf8)) ?? ""
    t.check(jpgScript.contains("--to jpg"), "JPG: skrypt konwertuje na jpg")
    t.check(pngScript.contains("--to png"), "PNG: skrypt konwertuje na png")
    t.check(jpgScript.contains(cli), "JPG: wpisana ścieżka do CLI")
    t.check(jpgScript.contains("--beside-source"), "JPG: zapis obok oryginału")

    let info = (try? String(contentsOf: jpgInfo, encoding: .utf8)) ?? ""
    t.check(info.contains("public.image"), "JPG: usługa przyjmuje pliki obrazów")
    t.check(info.contains("Konwertuj na JPG (Skryba)"), "JPG: nazwa pozycji w menu")
    t.check(info.contains("runWorkflowAsService"), "JPG: NSMessage usługi")

    t.check(FinderQuickAction.isInstalled(in: services), "isInstalled == true po instalacji")
    try FinderQuickAction.uninstall(from: services)
    t.check(!FinderQuickAction.isInstalled(in: services), "isInstalled == false po odinstalowaniu")
}
catch { t.check(false, "Test akcji Findera rzucił błąd: \(error)") }

// MARK: - Edytor PDF i podpisy

t.suite("Edytor PDF")

func makeTextImage(_ text: String, size: NSSize = NSSize(width: 360, height: 120)) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 16, y: 40),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black])
    img.unlockFocus()
    return img
}

func ocrCG(_ cg: CGImage) -> String {
    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
    req.recognitionLanguages = ["pl-PL", "en-US"]
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

func renderPDFPage(_ page: PDFPage) -> CGImage? {
    let b = page.bounds(for: .mediaBox)
    let s: CGFloat = 2
    let w = Int(b.width * s), h = Int(b.height * s)
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: s, y: s); page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-pdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Bazowy PDF z oryginalnym tekstem.
    let mdURL = dir.appendingPathComponent("oryginal.md")
    try "# ORYGINALNY TEKST\n\nTresc dokumentu do podpisu.".write(to: mdURL, atomically: true, encoding: .utf8)
    let pdfURL = try await DocumentConverter.convert(input: mdURL, to: .pdf, outputDirectory: dir)
    guard let doc = PDFDocument(url: pdfURL) else { t.check(false, "nie wczytano bazowego PDF"); throw CancellationError() }
    let startCount = doc.pageCount

    // Strony: wstaw obraz, usuń, sprawdź licznik.
    t.check(PDFEditing.insertImagePage(doc, image: makeTextImage("STRONA OBRAZ"), at: 1), "wstaw stronę-obraz")
    t.equal(doc.pageCount, startCount + 1, "po wstawieniu: +1 strona")
    t.check(PDFEditing.deletePage(doc, at: 1), "usuń stronę")
    t.equal(doc.pageCount, startCount, "po usunięciu: licznik wraca")

    // Adnotacje na stronie 0.
    guard let page0 = doc.page(at: 0) else { t.check(false, "brak strony 0"); throw CancellationError() }
    let pb = page0.bounds(for: .mediaBox)
    PDFEditing.addWhiteout(to: page0, bounds: CGRect(x: 40, y: pb.midY, width: 120, height: 24))
    PDFEditing.addText("PODPISANO", to: page0, bounds: CGRect(x: 40, y: 90, width: 240, height: 36), fontSize: 24)
    PDFEditing.addSignature(image: makeTextImage("PODPIS", size: NSSize(width: 300, height: 90)),
                            to: page0, bounds: CGRect(x: 40, y: 150, width: 220, height: 66))
    let stroke = NSBezierPath()
    stroke.move(to: NSPoint(x: pb.midX, y: 230)); stroke.line(to: NSPoint(x: pb.midX + 120, y: 250))
    PDFEditing.addInk(paths: [stroke], to: page0)
    t.check(page0.annotations.count >= 4, "dodano adnotacje (\(page0.annotations.count))")

    // Spłaszczenie i weryfikacja.
    guard let data = PDFEditing.flattenedData(doc), let flat = PDFDocument(data: data) else {
        t.check(false, "spłaszczenie nie powiodło się"); throw CancellationError()
    }
    t.equal(flat.pageCount, doc.pageCount, "flatten: liczba stron zachowana")
    t.check((flat.string ?? "").uppercased().contains("ORYGINALNY"), "flatten: oryginalny tekst zachowany")
    if let cg = renderPDFPage(flat.page(at: 0)!) {
        let ocr = ocrCG(cg).uppercased()
        t.check(ocr.contains("PODPISANO"), "flatten: pole tekstowe wtopione [\(ocr.prefix(50))]")
        t.check(ocr.contains("PODPIS"), "flatten: podpis-obraz wtopiony w PDF")
    } else { t.skip("nie udało się zrenderować strony do OCR") }

    // Wielostronicowy: usuń środkową, wstaw w środku — sprawdź kolejność (OCR).
    let multi = PDFDocument()
    for (i, label) in ["AAA", "BBB", "CCC"].enumerated() {
        if let page = PDFPage(image: makeTextImage(label, size: NSSize(width: 300, height: 400))) {
            multi.insert(page, at: i)
        }
    }
    t.equal(multi.pageCount, 3, "wielostr.: 3 strony na start")
    t.check(PDFEditing.deletePage(multi, at: 1), "wielostr.: usuń środkową (B)")
    func pageText(_ d: PDFDocument, _ i: Int) -> String {
        guard let p = d.page(at: i), let cg = renderPDFPage(p) else { return "" }
        return ocrCG(cg).uppercased()
    }
    t.check(pageText(multi, 0).contains("AAA") && pageText(multi, 1).contains("CCC"),
            "wielostr.: po usunięciu zostają A, C")
    // wstaw obraz X na pozycji 1 (między A i C)
    let xURL = dir.appendingPathComponent("x.png")
    if let data = NSBitmapImageRep(cgImage: makeTextImage("XXX", size: NSSize(width: 300, height: 400))
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!).representation(using: .png, properties: [:]) {
        try data.write(to: xURL)
        t.equal(PDFEditing.insertFile(multi, url: xURL, at: 1), 1, "wielostr.: wstaw X w środku")
        t.check(pageText(multi, 0).contains("AAA") && pageText(multi, 1).contains("XXX") && pageText(multi, 2).contains("CCC"),
                "wielostr.: kolejność A, X, C")
    }
}
catch is CancellationError {}
catch { t.check(false, "Test edytora PDF rzucił błąd: \(error)") }

// Wycinanie tła podpisu + biblioteka
do {
    let signed = makeTextImage("PODPIS", size: NSSize(width: 300, height: 100))
    guard let transparent = SignatureProcessor.removeBackground(signed),
          let cg = transparent.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        t.check(false, "removeBackground zwrócił nil"); throw CancellationError()
    }
    // Sprawdź, że są piksele przezroczyste (tło) i nieprzezroczyste (tusz).
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var transparentCount = 0, opaqueCount = 0
    for i in stride(from: 3, to: px.count, by: 4) {
        if px[i] == 0 { transparentCount += 1 } else if px[i] > 200 { opaqueCount += 1 }
    }
    t.check(transparentCount > 0, "removeBackground: tło stało się przezroczyste")
    t.check(opaqueCount > 0, "removeBackground: tusz pozostał widoczny")
    // Róg to papier — musi być CAŁKOWICIE przezroczysty (nie półprzezroczysty).
    t.check(px[3] == 0, "removeBackground: róg (papier) w pełni przezroczysty [alpha \(px[3])]")
    // Większość obrazu (papier) powinna zniknąć całkowicie.
    t.check(transparentCount > (w * h) / 2, "removeBackground: papier zniknął w większości [\(transparentCount)/\(w*h)]")

    // Biblioteka podpisów (w temp).
    let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-sig-\(UUID().uuidString)")
    let store = SignatureStore(directory: storeDir)
    defer { try? FileManager.default.removeItem(at: storeDir) }
    let url = try store.add(transparent)
    t.equal(store.all().count, 1, "biblioteka: dodano 1 podpis")
    t.check(store.image(url) != nil, "biblioteka: podpis się wczytuje")
    store.delete(url)
    t.equal(store.all().count, 0, "biblioteka: usunięto podpis")
}
catch is CancellationError {}
catch { t.check(false, "Test podpisów rzucił błąd: \(error)") }

// MARK: - Współrzędne edytora PDF (overlay → PDFView → strona)

t.suite("Współrzędne edytora PDF")

// Atrapa układu PDFView: pionowy stos `pageCount` stron pageWidth×pageHeight rozdzielonych
// pustą przerwą `gap`. Układ nakładki = układ widoku przesunięty o `overlayDelta` (pozwala
// sprawdzić, że konwersja overlay→view jest faktycznie stosowana). `pageIndex(forViewPoint:)`
// naśladuje nearest:true — punkt w przerwie lub poza stosem przyciąga do najbliższej strony;
// pusty dokument zwraca nil.
struct FakeStack: PDFCoordinateSpace {
    let pageCount: Int
    let pageWidth: CGFloat = 100
    let pageHeight: CGFloat = 200
    let gap: CGFloat = 40
    var overlayDelta: CGPoint = .zero

    var pitch: CGFloat { pageHeight + gap }
    func bandBottom(_ i: Int) -> CGFloat { CGFloat(i) * pitch }   // dolny brzeg pasma strony i (w układzie widoku)

    func overlayToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + overlayDelta.x, y: p.y + overlayDelta.y)
    }
    func pageIndex(forViewPoint p: CGPoint) -> Int? {
        guard pageCount > 0 else { return nil }
        var best = 0, bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<pageCount {
            let lo = bandBottom(i), hi = lo + pageHeight
            let d = p.y < lo ? lo - p.y : (p.y > hi ? p.y - hi : 0)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
    func viewToPage(_ p: CGPoint, pageIndex i: Int) -> CGPoint {
        CGPoint(x: p.x, y: p.y - bandBottom(i))
    }
    // Punkt nakładki, który trafia w stronę i w jej punkcie pp (do budowania danych testowych).
    func overlayPoint(page i: Int, pagePoint pp: CGPoint) -> CGPoint {
        CGPoint(x: pp.x - overlayDelta.x, y: pp.y + bandBottom(i) - overlayDelta.y)
    }
}

func approx(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
func approxPt(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { approx(a.x, b.x, eps) && approx(a.y, b.y, eps) }
func approxRect(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
    approx(a.minX, b.minX, eps) && approx(a.minY, b.minY, eps) && approx(a.width, b.width, eps) && approx(a.height, b.height, eps)
}

// Czysta geometria
t.check(approxRect(PDFCoordinateMath.normalizedRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 2, y: 40)),
                   CGRect(x: 2, y: 10, width: 8, height: 30)),
        "normalizedRect: rogi w dowolnej kolejności → nieujemny prostokąt")
t.check(approxRect(PDFCoordinateMath.normalizedRect(from: CGPoint(x: 2, y: 40), to: CGPoint(x: 10, y: 10)),
                   CGRect(x: 2, y: 10, width: 8, height: 30)),
        "normalizedRect: odwrócone rogi dają ten sam prostokąt")
t.check(approxPt(PDFCoordinateMath.midpoint(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20)), CGPoint(x: 5, y: 10)),
        "midpoint: środek odcinka")

// Round-trip: klik na konkretnej stronie wraca do tego samego punktu strony
do {
    let s = FakeStack(pageCount: 3)
    let pp = CGPoint(x: 30, y: 150)
    if let r = PDFCoordinateMapper.map(overlayPoint: s.overlayPoint(page: 2, pagePoint: pp), in: s) {
        t.check(r.pageIndex == 2, "map: trafiono w stronę 2")
        t.check(approxPt(r.pagePoint, pp), "map: round-trip punktu strony  [\(r.pagePoint)]")
    } else { t.check(false, "map: zwrócono nil dla punktu na stronie") }
}

// overlay→view jest stosowane (niezerowy delta nakładki)
do {
    let s = FakeStack(pageCount: 2, overlayDelta: CGPoint(x: 5, y: 7))
    let pp = CGPoint(x: 20, y: 60)
    if let r = PDFCoordinateMapper.map(overlayPoint: s.overlayPoint(page: 1, pagePoint: pp), in: s) {
        t.check(r.pageIndex == 1, "map(delta): trafiono w stronę 1")
        t.check(approxPt(r.pagePoint, pp), "map(delta): konwersja overlay→view uwzględniona  [\(r.pagePoint)]")
    } else { t.check(false, "map(delta): zwrócono nil") }
}

// nearest:true — klik w przerwie między stronami przyciąga do bliższej
do {
    let s = FakeStack(pageCount: 2)   // strona 0: y∈[0,200], przerwa [200,240], strona 1: [240,440]
    let near0 = PDFCoordinateMapper.map(overlayPoint: CGPoint(x: 50, y: 215), in: s)
    let near1 = PDFCoordinateMapper.map(overlayPoint: CGPoint(x: 50, y: 225), in: s)
    t.check(near0?.pageIndex == 0, "nearest: punkt w przerwie bliżej strony 0")
    t.check(near1?.pageIndex == 1, "nearest: punkt w przerwie bliżej strony 1")
}

// nearest:true — klik poza całym stosem przyciąga do skrajnej strony
do {
    let s = FakeStack(pageCount: 3)
    t.check(PDFCoordinateMapper.map(overlayPoint: CGPoint(x: 10, y: -50), in: s)?.pageIndex == 0,
            "nearest: poniżej stosu → strona 0")
    t.check(PDFCoordinateMapper.map(overlayPoint: CGPoint(x: 10, y: 99_999), in: s)?.pageIndex == 2,
            "nearest: powyżej stosu → ostatnia strona")
}

// Pusty dokument → nil, bez crasha (regresja force-unwrap z commitWhiteout)
do {
    let empty = FakeStack(pageCount: 0)
    t.check(PDFCoordinateMapper.map(overlayPoint: CGPoint(x: 1, y: 1), in: empty) == nil,
            "pusty dokument: map → nil (bez force-unwrap)")
    t.check(PDFCoordinateMapper.mapDragRect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 5, y: 5), in: empty) == nil,
            "pusty dokument: mapDragRect → nil")
    t.check(PDFCoordinateMapper.mapStroke([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], in: empty) == nil,
            "pusty dokument: mapStroke → nil")
}

// mapDragRect: normalizacja + oba rogi rzutowane na JEDNĄ stronę (w obrębie jednej strony)
do {
    let s = FakeStack(pageCount: 2)
    let a = s.overlayPoint(page: 1, pagePoint: CGPoint(x: 70, y: 120))
    let b = s.overlayPoint(page: 1, pagePoint: CGPoint(x: 20, y: 40))   // rogi w odwrotnej kolejności
    if let r = PDFCoordinateMapper.mapDragRect(from: a, to: b, in: s) {
        t.check(r.pageIndex == 1, "mapDragRect: strona ze środka przeciągnięcia")
        t.check(approxRect(r.rect, CGRect(x: 20, y: 40, width: 50, height: 80)),
                "mapDragRect: znormalizowany prostokąt w układzie strony  [\(r.rect)]")
    } else { t.check(false, "mapDragRect: zwrócono nil") }
}

// mapDragRect: przeciągnięcie przez granicę stron NIE miesza układów — oba rogi → strona środka
do {
    let s = FakeStack(pageCount: 2)
    let a = s.overlayPoint(page: 0, pagePoint: CGPoint(x: 10, y: 190))  // widok y = 190 (strona 0)
    let b = s.overlayPoint(page: 1, pagePoint: CGPoint(x: 60, y: 60))   // widok y = 300 (strona 1)
    let mid = 1   // środek widoku y = 245 ∈ [240,440] → strona 1
    let expected = PDFCoordinateMath.normalizedRect(
        from: s.viewToPage(s.overlayToView(a), pageIndex: mid),
        to:   s.viewToPage(s.overlayToView(b), pageIndex: mid))
    let r = PDFCoordinateMapper.mapDragRect(from: a, to: b, in: s)
    t.check(r?.pageIndex == mid, "mapDragRect (przez granicę): strona ze środka")
    t.check(r != nil && approxRect(r!.rect, expected),
            "mapDragRect (przez granicę): oba rogi w układzie tej samej strony  [\(String(describing: r?.rect))]")
}

// mapStroke: wszystkie punkty na stronie pierwszego punktu; kolejność i licznik zachowane
do {
    let s = FakeStack(pageCount: 2)
    let local = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 10)]
    let pts = local.map { s.overlayPoint(page: 1, pagePoint: $0) }
    if let r = PDFCoordinateMapper.mapStroke(pts, in: s) {
        t.check(r.pageIndex == 1, "mapStroke: strona pierwszego punktu")
        t.check(r.points.count == 3, "mapStroke: zachowano liczbę punktów")
        t.check(zip(r.points, local).allSatisfy { approxPt($0.0, $0.1) }, "mapStroke: punkty w układzie strony, kolejność zachowana")
    } else { t.check(false, "mapStroke: zwrócono nil") }
    t.check(PDFCoordinateMapper.mapStroke([], in: s) == nil, "mapStroke: pusta lista → nil")
}

// MARK: - Pobieranie z linku (yt-dlp)

t.suite("Pobieranie z linku")
t.check(MediaDownloader.isLikelyMediaURL("https://www.youtube.com/watch?v=abc"), "URL: youtube rozpoznany")
t.check(MediaDownloader.isLikelyMediaURL("https://x.com/i/status/123"), "URL: x.com rozpoznany")
t.check(!MediaDownloader.isLikelyMediaURL("nie-link"), "URL: tekst nie jest linkiem")
t.check(!MediaDownloader.isLikelyMediaURL("/sciezka/plik.mp4"), "URL: ścieżka nie jest linkiem")

if ProcessInfo.processInfo.environment["SKRYBA_NET_TEST"] == "1" {
    do {
        let dl = MediaDownloader.shared
        _ = try await dl.ensureYTDLP()
        let url = ProcessInfo.processInfo.environment["SKRYBA_NET_URL"] ?? "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        let info = try await dl.probe(url: url)
        t.check(!info.title.isEmpty, "probe: tytuł [\(info.title)]")
        t.check(!info.videoHeights.isEmpty, "probe: są rozdzielczości \(info.videoHeights)")
        t.check(info.hasAudio, "probe: jest ścieżka audio")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try await dl.downloadAudio(url: url, to: dir)
        t.check(FileManager.default.fileExists(atPath: audio.path), "download: plik audio powstał [\(audio.lastPathComponent)]")
        let samples = try await AudioDecoder.decode(url: audio)
        t.check(samples.count > 8000, "download: audio dekoduje się (\(samples.count) próbek)")

        // Pełny łańcuch: link → audio → transkrypcja (gdy jest model).
        if let modelPath = ProcessInfo.processInfo.environment["SKRYBA_E2E_MODEL"],
           FileManager.default.fileExists(atPath: modelPath) {
            let engine = try WhisperEngine(modelPath: modelPath)
            let segs = try engine.transcribe(samples: samples, language: "en")
            let text = segs.map(\.text).joined(separator: " ").lowercased()
            t.check(!text.trimmingCharacters(in: .whitespaces).isEmpty, "link→audio→transkrypcja: niepusta [\(text.prefix(50))]")
        }
    } catch {
        t.check(false, "Test sieciowy rzucił błąd: \(error)")
    }
} else {
    t.skip("ustaw SKRYBA_NET_TEST=1, aby pobrać i przetestować realny link")
}

// MARK: - Ekstrakcja PDF → Markdown (posiekana warstwa)

t.suite("PDF → Markdown")

// Detekcja „posiekanej” warstwy tekstowej (fragmenty jak w raporcie carVertical).
let garbled = """
Typ skrzyni biegów:A
ut
omat
yczna
Pojemność sk
k
o
owa układ
u
napędowego: 6,4 l
Moc
O
cena carVert
ical®
Be
ta
"""
let normalLayer = """
Umowa najmu lokalu mieszkalnego
Niniejsza umowa zostaje zawarta pomiędzy stronami w celu określenia warunków.
Wynajmujący oświadcza, że jest właścicielem lokalu i przekazuje go najemcy.
Najemca zobowiązuje się do terminowego regulowania czynszu oraz utrzymania.
Wszelkie zmiany niniejszej umowy wymagają formy pisemnej pod rygorem nieważności.
W sprawach nieuregulowanych stosuje się przepisy Kodeksu cywilnego.
"""
t.check(PDFExtractor.isGarbledLayer(garbled), "wykrywa posiekaną warstwę (dużo krótkich fragmentów)")
t.check(!PDFExtractor.isGarbledLayer(normalLayer), "nie myli normalnej warstwy z posiekaną")
t.check(PDFExtractor.needsOCR(pageString: garbled), "posiekana strona → OCR")
t.check(PDFExtractor.needsOCR(pageString: ""), "pusta strona (skan) → OCR")
t.check(!PDFExtractor.needsOCR(pageString: normalLayer), "dobra warstwa → bez OCR")

// Wykrywanie nagłówków po rozmiarze pisma, z odfiltrowaniem nie-nagłówków.
t.equal(PDFExtractor.classifyHeading(text: "Cena rynkowa", sizeRatio: 1.65), 3, "duże krótkie pismo → ### ")
t.equal(PDFExtractor.classifyHeading(text: "Specyfikacja i wyposażenie", sizeRatio: 1.9), 2, "bardzo duże pismo → ## ")
t.equal(PDFExtractor.classifyHeading(text: "88", sizeRatio: 2.0), 0, "sama liczba nie jest nagłówkiem")
t.equal(PDFExtractor.classifyHeading(text: "• Podsumowanie", sizeRatio: 1.6), 0, "punkt listy nie jest nagłówkiem")
t.equal(PDFExtractor.classifyHeading(text: "To jest zwykłe zdanie zakończone kropką.", sizeRatio: 1.6), 0, "zdanie z kropką nie jest nagłówkiem")
t.equal(PDFExtractor.classifyHeading(text: "Przebieg", sizeRatio: 1.0), 0, "przeciętne pismo → akapit")

// Czyszczenie wiodących śmieci-ikon z OCR (bez ruszania liczb i skrótów).
t.equal(PDFExtractor.stripLeadingIconJunk("+* Wykładzina na podłodze"), "Wykładzina na podłodze", "ikona: usuwa '+*'")
t.equal(PDFExtractor.stripLeadingIconJunk("o= Czy pojazd przeszedł przegląd?"), "Czy pojazd przeszedł przegląd?", "ikona: usuwa 'o='")
t.equal(PDFExtractor.stripLeadingIconJunk("® Kradzież"), "Kradzież", "ikona: usuwa '®'")
t.equal(PDFExtractor.stripLeadingIconJunk("354 kW mocy"), "354 kW mocy", "ikona: nie rusza liczby '354'")
t.equal(PDFExtractor.stripLeadingIconJunk("6,4 l pojemności"), "6,4 l pojemności", "ikona: nie rusza '6,4'")
t.equal(PDFExtractor.stripLeadingIconJunk("np. taksówka"), "np. taksówka", "ikona: nie rusza skrótu 'np.'")

// Sklejanie zawiniętych linii w akapity + osobny nagłówek.
let merged = PDFExtractor.mergeParagraphs([
    .init(text: "Sprawdzenie statusu prawnego"),
    .init(text: "i finansowego"),
    .init(text: "Cena rynkowa", sizeRatio: 1.65),
    .init(text: "Nie stwierdzono ryzyka"),
    .init(text: "finansowego ani prawnego."),
])
t.equal(merged.count, 3, "merge: 3 bloki (akapit, nagłówek, akapit)")
t.equal(merged.first?.text, "Sprawdzenie statusu prawnego i finansowego", "merge: zawinięta linia doklejona")
t.check(merged.contains { $0.heading == 3 && $0.text == "Cena rynkowa" }, "merge: nagłówek zachowany osobno")
t.equal(merged.last?.text, "Nie stwierdzono ryzyka finansowego ani prawnego.", "merge: drugi akapit sklejony")

// Usuwanie powtarzalnej stopki: warianty różniące się tylko datą/numerem znikają
// (klucz pomija cyfry), a treść różniąca się słowami zostaje.
let uniqueWords = ["kotach", "psach", "domu", "lesie", "rzece"]
let pages = (0..<5).map { i in
    [PDFExtractor.Line(text: "Wygenerowano 0\(i).07.2026 | Strona \(i)"),
     PDFExtractor.Line(text: "Rozdział o \(uniqueWords[i]) i jego historii")]
}
let cleaned = PDFExtractor.dropBoilerplate(pages)
t.check(cleaned.allSatisfy { $0.count == 1 }, "boilerplate: stopka (różne daty) usunięta z każdej strony")
t.check(cleaned.allSatisfy { $0.first?.text.hasPrefix("Rozdział o") == true }, "boilerplate: treść (różne słowa) zachowana")

// Opcjonalny test end-to-end na realnym pliku PDF (ustaw SKRYBA_PDF_TEST=ścieżka).
if let pdfPath = ProcessInfo.processInfo.environment["SKRYBA_PDF_TEST"],
   FileManager.default.fileExists(atPath: pdfPath) {
    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("skryba-pdfmd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let out = try await DocumentConverter.convert(input: URL(fileURLWithPath: pdfPath), to: .md, outputDirectory: base)
        let md = try String(contentsOf: out, encoding: .utf8)
        let lines = md.split(separator: "\n", omittingEmptySubsequences: true)
        let singleChar = lines.filter { $0.trimmingCharacters(in: .whitespaces).count == 1 }.count
        t.check(md.count > 200, "PDF E2E: powstał niepusty Markdown (\(md.count) znaków)")
        t.check(singleChar <= 3, "PDF E2E: brak posiekania — prawie brak jednoznakowych linii (\(singleChar))")
        t.check(md.contains("# "), "PDF E2E: są nagłówki Markdown")
    } catch {
        t.check(false, "PDF E2E rzucił błąd: \(error)")
    }
} else {
    t.skip("ustaw SKRYBA_PDF_TEST=ścieżka/do.pdf, aby przetestować realny PDF")
}

// MARK: - Transformacje adnotacji (AABB, uchwyty, obrót, skalowanie)

t.suite("Transformacje adnotacji")

// AABB: bez obrotu == rozmiar; przy 90° wymiary zamienione; przy 45° kwadrat rośnie.
do {
    let box0 = AnnotationTransform.boundingBox(displaySize: CGSize(width: 200, height: 60),
                                               center: CGPoint(x: 100, y: 100), rotationDegrees: 0)
    t.check(approxRect(box0, CGRect(x: 0, y: 70, width: 200, height: 60)), "AABB: obrót 0° == displaySize [\(box0)]")

    let box90 = AnnotationTransform.boundingBox(displaySize: CGSize(width: 200, height: 60),
                                                center: CGPoint(x: 100, y: 100), rotationDegrees: 90)
    t.check(approx(box90.width, 60) && approx(box90.height, 200), "AABB: obrót 90° zamienia wymiary (60×200) [\(box90)]")
    t.check(approx(box90.midX, 100) && approx(box90.midY, 100), "AABB: obrót wokół środka (środek bez zmian)")

    let box180 = AnnotationTransform.boundingBox(displaySize: CGSize(width: 200, height: 60),
                                                 center: CGPoint(x: 100, y: 100), rotationDegrees: 180)
    t.check(approx(box180.width, 200) && approx(box180.height, 60), "AABB: obrót 180° == wymiary wyjściowe")

    let sq45 = AnnotationTransform.boundingBox(displaySize: CGSize(width: 100, height: 100),
                                               center: .zero, rotationDegrees: 45)
    t.check(sq45.width > 100 && sq45.height > 100, "AABB: kwadrat przy 45° rośnie (≈141) [\(sq45.width)]")
    t.check(approx(sq45.width, 100 * sqrt(2), 0.01), "AABB: 45° = bok·√2")
}

// Kąt obrotu z pozycji uchwytu (uchwyt w górę = 0°).
do {
    let c = CGPoint(x: 50, y: 50)
    t.check(approx(AnnotationTransform.rotationDegrees(center: c, handlePoint: CGPoint(x: 50, y: 80)), 0),
            "kąt: uchwyt w górę → 0°")
    t.check(approx(AnnotationTransform.rotationDegrees(center: c, handlePoint: CGPoint(x: 80, y: 50)), -90),
            "kąt: uchwyt w prawo → -90°")
    t.check(approx(AnnotationTransform.rotationDegrees(center: c, handlePoint: CGPoint(x: 20, y: 50)), 90),
            "kąt: uchwyt w lewo → 90°")
    t.check(approx(abs(AnnotationTransform.rotationDegrees(center: c, handlePoint: CGPoint(x: 50, y: 20))), 180),
            "kąt: uchwyt w dół → 180°")
}

// Przyciąganie kąta do 15° i normalizacja.
t.check(approx(AnnotationTransform.snapAngle(7), 0), "snap 15°: 7° → 0°")
t.check(approx(AnnotationTransform.snapAngle(8), 15), "snap 15°: 8° → 15°")
t.check(approx(AnnotationTransform.snapAngle(37), 30), "snap 15°: 37° → 30°")
t.check(approx(AnnotationTransform.snapAngle(38), 45), "snap 15°: 38° → 45°")
t.check(approx(AnnotationTransform.normalizeDegrees(270), -90), "normalizacja: 270° → -90°")
t.check(approx(AnnotationTransform.normalizeDegrees(-270), 90), "normalizacja: -270° → 90°")

// Uchwyt obrotu leży nad środkiem górnej krawędzi (przy 0° prosto w górę).
do {
    let rp = AnnotationTransform.handlePoint(.rotation, center: CGPoint(x: 0, y: 0),
                                             size: CGSize(width: 40, height: 40), rotationDegrees: 0, rotationArm: 26)
    t.check(approx(rp.x, 0) && approx(rp.y, 46), "uchwyt obrotu: nad górną krawędzią (y = hh + arm)")
}

// Trafienie w uchwyt: najbliższy w promieniu, poza promieniem → nil.
do {
    let center = CGPoint(x: 100, y: 100), size = CGSize(width: 80, height: 80)
    let hs: [AnnotationTransform.Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight, .rotation]
    let br = AnnotationTransform.handlePoint(.bottomRight, center: center, size: size, rotationDegrees: 0)
    t.equal(AnnotationTransform.hitHandle(hs, point: br, center: center, size: size, rotationDegrees: 0, radius: 10),
            .bottomRight, "hit: trafiono narożnik dolny-prawy")
    t.check(AnnotationTransform.hitHandle(hs, point: center, center: center, size: size, rotationDegrees: 0, radius: 10) == nil,
            "hit: środek poza uchwytami → nil")
}

// Skalowanie swobodne: narożnik dolny-prawy, kotwica (górny-lewy) nieruchoma.
do {
    let r = AnnotationTransform.resize(center: CGPoint(x: 100, y: 100), size: CGSize(width: 40, height: 40),
                                       rotationDegrees: 0, handle: .bottomRight,
                                       toCursor: CGPoint(x: 140, y: 60), proportional: false)
    t.check(approx(r.size.width, 60) && approx(r.size.height, 60), "skala swobodna: nowy rozmiar 60×60 [\(r.size)]")
    t.check(approxPt(r.center, CGPoint(x: 110, y: 90)), "skala swobodna: środek przesunięty, kotwica stała [\(r.center)]")
    // Górny-lewy narożnik (kotwica) nie drgnął.
    let anchor = AnnotationTransform.handlePoint(.topLeft, center: r.center, size: r.size, rotationDegrees: 0)
    t.check(approxPt(anchor, CGPoint(x: 80, y: 120)), "skala swobodna: kotwica (80,120) nieruchoma")
}

// Skalowanie proporcjonalne: zachowuje proporcje boków (2.5:1).
do {
    let r = AnnotationTransform.resize(center: .zero, size: CGSize(width: 100, height: 40),
                                       rotationDegrees: 0, handle: .bottomRight,
                                       toCursor: CGPoint(x: 150, y: -60), proportional: true)
    t.check(approx(r.size.width / r.size.height, 2.5, 1e-4), "skala proporcjonalna: proporcje zachowane [\(r.size)]")
    t.check(r.size.width > 100, "skala proporcjonalna: powiększenie")
}

// Minimalny rozmiar: ciągnięcie na kotwicę nie schodzi poniżej 24 pt.
do {
    let free = AnnotationTransform.resize(center: CGPoint(x: 100, y: 100), size: CGSize(width: 40, height: 40),
                                          rotationDegrees: 0, handle: .bottomRight,
                                          toCursor: CGPoint(x: 80, y: 120), proportional: false, minSize: 24)
    t.check(free.size.width >= 24 && free.size.height >= 24, "min-size: swobodne klamruje do 24 [\(free.size)]")
    let prop = AnnotationTransform.resize(center: .zero, size: CGSize(width: 100, height: 40),
                                          rotationDegrees: 0, handle: .bottomRight,
                                          toCursor: .zero, proportional: true, minSize: 24)
    t.check(prop.size.width >= 24 && prop.size.height >= 24, "min-size: proporcjonalne klamruje oba boki [\(prop.size)]")
}

// Skalowanie krawędzią (Square): uchwyt górnej krawędzi zmienia tylko wysokość.
do {
    let r = AnnotationTransform.resize(center: CGPoint(x: 100, y: 100), size: CGSize(width: 40, height: 40),
                                       rotationDegrees: 0, handle: .top,
                                       toCursor: CGPoint(x: 100, y: 160), proportional: false)
    t.check(approx(r.size.width, 40), "skala krawędzią: szerokość bez zmian")
    t.check(approx(r.size.height, 80), "skala krawędzią: nowa wysokość 80")
    t.check(approxPt(r.center, CGPoint(x: 100, y: 120)), "skala krawędzią: dolna krawędź (kotwica) stała [\(r.center)]")
}

// Skalowanie z obrotem 90°: kotwica (przeciwległy narożnik) pozostaje nieruchoma.
do {
    let center = CGPoint(x: 100, y: 100), size = CGSize(width: 40, height: 20)
    let anchorBefore = AnnotationTransform.handlePoint(.topLeft, center: center, size: size, rotationDegrees: 90)
    let cursor = CGPoint(x: 130, y: 130)
    let r = AnnotationTransform.resize(center: center, size: size, rotationDegrees: 90,
                                       handle: .bottomRight, toCursor: cursor, proportional: false)
    let anchorAfter = AnnotationTransform.handlePoint(.topLeft, center: r.center, size: r.size, rotationDegrees: 90)
    t.check(approxPt(anchorBefore, anchorAfter), "skala z obrotem 90°: kotwica nieruchoma [\(anchorBefore) → \(anchorAfter)]")
}

// MARK: - Obrót adnotacji obrazkowej i jego zachowanie przy spłaszczeniu

t.suite("Obrót podpisu (flatten)")

func makeSolidImage(_ color: NSColor, size: NSSize) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    color.setFill(); NSRect(origin: .zero, size: size).fill()
    img.unlockFocus()
    return img
}

// Prostokąt kolorowych pikseli (czerwień) w renderze — układ i rozmiar (do sprawdzenia obrotu).
func redBoundingBox(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1, count = 0
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            if px[o] > 150 && px[o + 1] < 100 && px[o + 2] < 100 {
                count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard count > 0, maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

do {
    let page = PDFPage(image: makeSolidImage(.white, size: NSSize(width: 600, height: 600)))!
    let center = CGPoint(x: 300, y: 300)
    let disp = CGSize(width: 200, height: 60)                       // szeroki, niski prostokąt
    let stampImg = makeSolidImage(.red, size: NSSize(width: 200, height: 60))

    // Bez obrotu: AABB == displaySize, render szeroki.
    let flat = ImageStampAnnotation(image: stampImg,
                                    bounds: CGRect(x: center.x - 100, y: center.y - 30, width: 200, height: 60))
    t.check(approxRect(flat.bounds, CGRect(x: 200, y: 270, width: 200, height: 60)),
            "flatten: bez obrotu AABB == displaySize [\(flat.bounds)]")

    let docFlat = PDFDocument(); docFlat.insert(page.copy() as! PDFPage, at: 0)
    docFlat.page(at: 0)!.addAnnotation(flat)
    guard let dataFlat = PDFEditing.flattenedData(docFlat), let outFlat = PDFDocument(data: dataFlat),
          let cgFlat = renderPDFPage(outFlat.page(at: 0)!), let bbFlat = redBoundingBox(cgFlat) else {
        t.check(false, "flatten bez obrotu: render nie powiódł się"); throw CancellationError()
    }
    t.check(bbFlat.width > bbFlat.height, "flatten: bez obrotu render szeroki (szer > wys) [\(bbFlat)]")

    // Z obrotem 90°: AABB zamienia wymiary, render wysoki — piksele NIE tam, gdzie bez obrotu.
    let rot = ImageStampAnnotation(image: stampImg,
                                   bounds: CGRect(x: center.x - 100, y: center.y - 30, width: 200, height: 60))
    rot.applyTransform(center: center, displaySize: disp, rotationDegrees: 90)
    t.check(approx(rot.bounds.width, 60) && approx(rot.bounds.height, 200),
            "obrót 90°: AABB = 60×200 [\(rot.bounds)]")

    let docRot = PDFDocument(); docRot.insert(page.copy() as! PDFPage, at: 0)
    docRot.page(at: 0)!.addAnnotation(rot)
    guard let dataRot = PDFEditing.flattenedData(docRot), let outRot = PDFDocument(data: dataRot),
          let cgRot = renderPDFPage(outRot.page(at: 0)!), let bbRot = redBoundingBox(cgRot) else {
        t.check(false, "flatten z obrotem: render nie powiódł się"); throw CancellationError()
    }
    t.check(bbRot.height > bbRot.width, "flatten: obrót 90° render wysoki (wys > szer) — obrót zachowany [\(bbRot)]")
    // Powierzchnia czerwieni podobna (obrót nie ucina obrazu, tylko obraca).
    let ratio = Double(bbRot.width * bbRot.height) / Double(max(1, bbFlat.width * bbFlat.height))
    t.check(ratio > 0.8 && ratio < 1.25, "flatten: obrót zachowuje powierzchnię obrazu (≈1.0) [\(String(format: "%.2f", ratio))]")
}
catch is CancellationError {}
catch { t.check(false, "Test obrotu podpisu rzucił błąd: \(error)") }

t.finish()
