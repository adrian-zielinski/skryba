import Foundation
import AppKit
import Accelerate
import Vision

/// Przygotowanie podpisów: wycięcie tła (zdjęcie z kartki → przezroczysty
/// podpis), render narysowanego podpisu oraz konwersja do PNG.
public enum SignatureProcessor {

    /// Usuwa tło (kartkę) ze zdjęcia podpisu, pieczątki albo tekstu, zostawiając
    /// samą treść z przezroczystością. Jakość klasy „remove.bg":
    /// 1. normalizacja oświetlenia (dzielenie przez tło z rozmycia Gaussa) usuwa
    ///    cienie, winiety i gradienty — kartka staje się jednolicie biała;
    /// 2. maska tuszu z dwóch sygnałów: ciemność (Otsu na znormalizowanej
    ///    luminancji) LUB barwność (odległość od szarości) — łapie też jasne
    ///    kolorowe tusze i pieczątki;
    /// 3. odszumianie: małe izolowane komponenty (pyłki) znikają, ale drobiny
    ///    przy dużych kształtach (kropka nad „i") są chronione;
    /// 4. kolor brany ze znormalizowanego obrazu (bez zafarbu papieru), zapis
    ///    premultiplied; czarny zostaje czarny, niebieski niebieski.
    /// Wynik przycięty do zawartości z marginesem 8 px, PNG z przezroczystością.
    ///
    /// Parametry `whiteThreshold`/`gain` pozostają dla zgodności wywołań — nowy
    /// potok dobiera progi automatycznie i ich nie potrzebuje.
    public static func removeBackground(_ input: NSImage,
                                        whiteThreshold: CGFloat = 0,
                                        gain: CGFloat = 0) -> NSImage? {
        guard let raw = input.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Ograniczenie rozdzielczości roboczej: zdjęcia z telefonu bywają 24–48 Mpx, a podpis
        // ląduje w PDF przy ~180 pt szerokości — pełna rozdzielczość tylko zamula i zżera pamięć
        // (kilka pełnoklatkowych buforów + splot + spójne komponenty). Skalujemy w dół dłuższy bok.
        let cg = downscaled(raw, maxLongerSide: 2000)
        guard let base = process(cg) else { return nil }

        // Awaryjnie: jeśli maska pokrywa prawie cały obraz albo prawie nic, to
        // zwykle nie jest kartka (zdjęcie na stole/kolorowym tle). Ogranicz obszar
        // maską pierwszego planu z Vision i puść potok na wycinku.
        if base.coverage > 0.45 || base.coverage < 0.0002 {
            if #available(macOS 14.0, *),
               let bbox = foregroundBoundingBox(cg),
               let crop = cg.cropping(to: bbox),
               let refined = process(crop) {
                return refined.image
            }
        }
        return base.image
    }

    /// Zmniejsza obraz tak, by dłuższy bok nie przekraczał `maxLongerSide` (zachowuje proporcje).
    /// Mniejsze obrazy zwraca bez zmian.
    private static func downscaled(_ cg: CGImage, maxLongerSide: Int) -> CGImage {
        let longer = max(cg.width, cg.height)
        guard longer > maxLongerSide else { return cg }
        let scale = Double(maxLongerSide) / Double(longer)
        let w = max(1, Int((Double(cg.width) * scale).rounded()))
        let h = max(1, Int((Double(cg.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    // MARK: - Rdzeń potoku

    private struct Result { let image: NSImage; let coverage: Double }

    /// Pełny potok na jednym obrazie. Zwraca gotowy (przycięty) obraz i pokrycie
    /// maski (udział pikseli tuszu w całości) — pokrycie steruje trybem awaryjnym.
    private static func process(_ cg: CGImage) -> Result? {
        let width = cg.width, height = cg.height
        guard width > 1, height > 1 else { return nil }
        let count = width * height * 4

        // Wejście do RGBA8 (papier jest kryjący, więc premultiplied == proste).
        var pixels = [UInt8](repeating: 0, count: count)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 1. Tło = duże rozmycie (Gauss ≈ trzy przebiegi pudełkowe, vImage, O(N)).
        //    Promień ~4% dłuższego boku — cieńsze od kresek, więc tusz w nim ginie,
        //    a zostaje sam gradient oświetlenia papieru.
        guard let bg = estimateBackground(pixels, width: width, height: height) else { return nil }

        // 2a. Histogram znormalizowanej luminancji → próg Otsu (ciemność).
        var histogram = [Int](repeating: 0, count: 256)
        for p in 0..<(width * height) {
            let i = p * 4
            let rn = norm(pixels[i],     bg[i])
            let gn = norm(pixels[i + 1], bg[i + 1])
            let bn = norm(pixels[i + 2], bg[i + 2])
            let lum = Int((0.299 * rn + 0.587 * gn + 0.114 * bn).rounded())
            histogram[min(255, max(0, lum))] += 1
        }
        // Ograniczenie górne: przy twardej krawędzi cienia (np. ½ kartki ×0,6) rozmyte tło
        // jest tam mieszaniną obu stron, więc iloraz daje umiarkowane przyciemnienie (~0,75).
        // Tusz jest DUŻO ciemniejszy, więc czapkujemy próg — krawędzie cienia nie wchodzą do maski.
        // Ale czapka odcina też blady tusz (ołówek, jasny żel) na równomiernie oświetlonym
        // papierze, więc stosujemy ją TYLKO gdy tło ma silny gradient jasności (jest cień).
        let otsu = Double(otsuThreshold(histogram, total: width * height))
        let threshold = backgroundLuminanceSpread(bg, count: width * height) > 40 ? min(otsu, 180.0) : otsu
        let band = 40.0                 // pasmo antyaliasingu krawędzi (skala 0–255)
        let chromaLow = 28.0, chromaHigh = 60.0   // barwność: pasmo przejściowe

        // 2b. Alpha + znormalizowany kolor (prosty, nie premultiplied — mnożymy po
        //     odszumianiu). Maska kandydatów na tusz: alpha > 40.
        var alpha = [UInt8](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            let i = p * 4
            let rn = norm(pixels[i],     bg[i])
            let gn = norm(pixels[i + 1], bg[i + 1])
            let bn = norm(pixels[i + 2], bg[i + 2])
            let lum = 0.299 * rn + 0.587 * gn + 0.114 * bn
            let chroma = max(rn, max(gn, bn)) - min(rn, min(gn, bn))

            // Ciemność: poniżej progu tusz, płynna krawędź w paśmie.
            var aDark = 0.0
            if lum < threshold {
                aDark = min(1.0, (threshold - lum) / band)
            }
            // Barwność: wyraźnie kolorowe piksele (nawet jasne) to tusz.
            var aColor = 0.0
            if chroma > chromaLow {
                aColor = min(1.0, (chroma - chromaLow) / (chromaHigh - chromaLow))
            }
            var a = max(aDark, aColor)
            if a < 0.06 { a = 0 }

            pixels[i]     = UInt8(min(255, max(0, rn)).rounded())
            pixels[i + 1] = UInt8(min(255, max(0, gn)).rounded())
            pixels[i + 2] = UInt8(min(255, max(0, bn)).rounded())
            alpha[p] = UInt8((a * 255).rounded())
        }

        // 3. Odszumianie: usuń małe izolowane komponenty (pyłki), chroniąc drobiny
        //    stykające się/leżące blisko dużych kształtów (kropka nad „i").
        denoise(&alpha, width: width, height: height)

        // 4. Premultiply + zawartość do przycięcia.
        var minX = width, minY = height, maxX = -1, maxY = -1
        var inkCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let a = alpha[p]
                let i = p * 4
                if a == 0 {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                    continue
                }
                let af = Double(a) / 255
                pixels[i]     = UInt8((Double(pixels[i])     * af).rounded())
                pixels[i + 1] = UInt8((Double(pixels[i + 1]) * af).rounded())
                pixels[i + 2] = UInt8((Double(pixels[i + 2]) * af).rounded())
                pixels[i + 3] = a
                inkCount += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }

        guard let output = CGContext(data: &pixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .makeImage() else { return nil }
        let coverage = Double(inkCount) / Double(width * height)

        if maxX >= minX, maxY >= minY {
            let pad = 8
            let cropX = max(0, minX - pad)
            let cropY = max(0, minY - pad)
            let cropW = min(width - cropX, maxX - minX + 1 + 2 * pad)
            let cropH = min(height - cropY, maxY - minY + 1 + 2 * pad)
            if let cropped = output.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) {
                return Result(image: NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)),
                              coverage: coverage)
            }
        }
        return Result(image: NSImage(cgImage: output, size: NSSize(width: width, height: height)),
                      coverage: coverage)
    }

    /// Rozpiętość jasności tła (papieru) po rozmyciu: max − min luminancji. Duża wartość
    /// oznacza silny gradient oświetlenia / twardy cień; mała — papier oświetlony równomiernie.
    private static func backgroundLuminanceSpread(_ bg: [UInt8], count: Int) -> Double {
        var lo = 255.0, hi = 0.0
        for p in 0..<count {
            let i = p * 4
            let lum = 0.299 * Double(bg[i]) + 0.587 * Double(bg[i + 1]) + 0.114 * Double(bg[i + 2])
            if lum < lo { lo = lum }
            if lum > hi { hi = lum }
        }
        return hi - lo
    }

    /// Znormalizowana wartość kanału (0–255): piksel / tło, obcięta do 255.
    /// Papier → ~255, tusz → wyraźnie mniej, niezależnie od cienia/gradientu.
    @inline(__always)
    private static func norm(_ v: UInt8, _ bg: UInt8) -> Double {
        min(255.0, 255.0 * Double(v) / Double(max(1, Int(bg))))
    }

    /// Tło (papier) z trzech przebiegów rozmycia pudełkowego ≈ Gauss. vImage liczy
    /// to w czasie liniowym niezależnie od promienia, więc 12 Mpx mieści się w budżecie.
    private static func estimateBackground(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let count = width * height * 4
        let longer = max(width, height)
        var radius = Int(0.04 * Double(longer))
        radius = max(2, radius)
        var k = 2 * radius + 1
        if k % 2 == 0 { k += 1 }
        // Kernel nie może przekroczyć wymiarów obrazu (vImage tego wymaga).
        k = min(k, (min(width, height) / 2) * 2 - 1)
        if k < 3 { k = 3 }

        let bgRaw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        let tmpRaw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { bgRaw.deallocate(); tmpRaw.deallocate() }

        var src = pixels
        let ok = src.withUnsafeMutableBytes { srcBytes -> Bool in
            guard let srcBase = srcBytes.baseAddress else { return false }
            var sBuf = vImage_Buffer(data: srcBase, height: vImagePixelCount(height),
                                     width: vImagePixelCount(width), rowBytes: width * 4)
            var bBuf = vImage_Buffer(data: bgRaw, height: vImagePixelCount(height),
                                     width: vImagePixelCount(width), rowBytes: width * 4)
            var tBuf = vImage_Buffer(data: tmpRaw, height: vImagePixelCount(height),
                                     width: vImagePixelCount(width), rowBytes: width * 4)
            // Krawędzie przez rozszerzenie (kvImageEdgeExtend) — kolor tła nieużywany, więc nil.
            let flags = vImage_Flags(kvImageEdgeExtend)
            let kh = UInt32(k), kw = UInt32(k)
            if vImageBoxConvolve_ARGB8888(&sBuf, &bBuf, nil, 0, 0, kh, kw, nil, flags) != kvImageNoError { return false }
            if vImageBoxConvolve_ARGB8888(&bBuf, &tBuf, nil, 0, 0, kh, kw, nil, flags) != kvImageNoError { return false }
            if vImageBoxConvolve_ARGB8888(&tBuf, &bBuf, nil, 0, 0, kh, kw, nil, flags) != kvImageNoError { return false }
            return true
        }
        guard ok else { return nil }

        let ptr = bgRaw.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    /// Usuwa małe izolowane komponenty maski (pyłki, ziarno). Komponent znika,
    /// gdy jest znacznie mniejszy od największego I leży dalej niż `gap` od każdego
    /// dużego komponentu — dzięki temu kropka nad „i" czy przecinek przy piśmie
    /// zostają, a odległe drobiny są czyszczone.
    private static func denoise(_ alpha: inout [UInt8], width: Int, height: Int) {
        let n = width * height
        var label = [Int32](repeating: 0, count: n)   // 0 = nieodwiedzone/tło
        var areas: [Int] = [0]                          // areas[label]
        var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = [(0, 0, 0, 0)]
        var stack = [Int]()
        stack.reserveCapacity(1024)
        var current: Int32 = 0

        @inline(__always) func isInk(_ p: Int) -> Bool { alpha[p] > 40 }

        for start in 0..<n {
            if !isInk(start) || label[start] != 0 { continue }
            current += 1
            areas.append(0)
            var bx = (minX: width, minY: height, maxX: -1, maxY: -1)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            label[start] = current
            while let p = stack.popLast() {
                areas[Int(current)] += 1
                let x = p % width, y = p / width
                if x < bx.minX { bx.minX = x }; if x > bx.maxX { bx.maxX = x }
                if y < bx.minY { bx.minY = y }; if y > bx.maxY { bx.maxY = y }
                // 8-spójność.
                var dy = -1
                while dy <= 1 {
                    var dx = -1
                    while dx <= 1 {
                        if dx != 0 || dy != 0 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, nx < width, ny >= 0, ny < height {
                                let q = ny * width + nx
                                if label[q] == 0, isInk(q) {
                                    label[q] = current
                                    stack.append(q)
                                }
                            }
                        }
                        dx += 1
                    }
                    dy += 1
                }
            }
            boxes.append(bx)
        }
        if current == 0 { return }

        // „Pyłek" = bardzo mały komponent (próg bezwzględny, skalowany rozmiarem obrazu).
        // Wszystko powyżej to kotwica: kreski, bloki, ale też przecinki. Pyłek znika tylko,
        // gdy jest odległy od każdej kotwicy — drobina przy piśmie (kropka nad „i") zostaje.
        let dustThreshold = max(12, Int(Double(width * height) * 5e-6))
        let gap = max(6, Int(0.01 * Double(max(width, height))))
        var anchorBoxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        for l in 1...Int(current) where areas[l] >= dustThreshold { anchorBoxes.append(boxes[l]) }

        var removeLabel = [Bool](repeating: false, count: Int(current) + 1)
        for l in 1...Int(current) {
            if areas[l] >= dustThreshold { continue }       // kotwica → zostaje
            let b = boxes[l]
            var nearAnchor = false
            for anchor in anchorBoxes {
                let dx = max(0, max(b.minX - anchor.maxX, anchor.minX - b.maxX))
                let dy = max(0, max(b.minY - anchor.maxY, anchor.minY - b.maxY))
                if dx * dx + dy * dy <= gap * gap { nearAnchor = true; break }
            }
            if !nearAnchor { removeLabel[l] = true }         // mały i odległy → pyłek
        }

        for p in 0..<n {
            let l = label[p]
            if l != 0 && removeLabel[Int(l)] { alpha[p] = 0 }
        }
    }

    /// Prostokąt (w pikselach obrazu) obejmujący pierwszy plan wg Vision. Używane
    /// tylko w trybie awaryjnym, gdy potok podstawowy dał podejrzane pokrycie.
    @available(macOS 14.0, *)
    private static func foregroundBoundingBox(_ cg: CGImage) -> CGRect? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first else { return nil }
        guard let mask = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let ptr = base.assumingMemoryBound(to: Float.self)
        let stride = rowBytes / MemoryLayout<Float>.size

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = ptr + y * stride
            for x in 0..<w where row[x] > 0.5 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Maska bywa przeskalowana do innego rozmiaru niż obraz — przelicz na piksele cg.
        let sx = CGFloat(cg.width) / CGFloat(w)
        let sy = CGFloat(cg.height) / CGFloat(h)
        let pad: CGFloat = 4
        let rx = max(0, CGFloat(minX) * sx - pad)
        let ry = max(0, CGFloat(minY) * sy - pad)
        let rw = min(CGFloat(cg.width) - rx, CGFloat(maxX - minX + 1) * sx + 2 * pad)
        let rh = min(CGFloat(cg.height) - ry, CGFloat(maxY - minY + 1) * sy + 2 * pad)
        guard rw > 1, rh > 1 else { return nil }
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    /// Próg Otsu: maksymalizuje wariancję międzyklasową (tusz vs papier).
    private static func otsuThreshold(_ histogram: [Int], total: Int) -> Int {
        guard total > 0 else { return 200 }
        var sum = 0.0
        for t in 0..<256 { sum += Double(t) * Double(histogram[t]) }
        var sumB = 0.0, wB = 0
        var maxVariance = -1.0
        // Gdy tusz i papier są rozdzielone pustym pasmem (czyste bimodalne histogramy),
        // wariancja jest jednakowa na całym paśmie — bierzemy jego środek, nie krawędź,
        // żeby próg wypadł MIĘDZY klasami (inaczej „lum < próg" nie łapie nic).
        var lowAtMax = 128, highAtMax = 128
        for t in 0..<256 {
            wB += histogram[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t) * Double(histogram[t])
            let meanB = sumB / Double(wB)
            let meanF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (meanB - meanF) * (meanB - meanF)
            if between > maxVariance { maxVariance = between; lowAtMax = t; highAtMax = t }
            else if between == maxVariance { highAtMax = t }
        }
        return (lowAtMax + highAtMax) / 2
    }

    /// Renderuje narysowane ślady (podpis z myszki) na przezroczystym tle.
    public static func image(fromPaths paths: [NSBezierPath], size: NSSize,
                             color: NSColor = .black, lineWidth: CGFloat = 3) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setStroke()
        for path in paths {
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        image.unlockFocus()
        return image
    }

    public static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
