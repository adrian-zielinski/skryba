import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Konwersja obrazów między formatami rastrowymi (cel: PNG lub JPG).
///
/// Silnik natywny (ImageIO / Core Graphics / Core Image), bez zewnętrznych zależności.
/// Czyta wszystko, co potrafi macOS: DNG i inne RAW-y, HEIC/HEIF, JPG, PNG, TIFF, GIF, BMP, WebP.
/// Orientacja EXIF jest wypalana w piksele, a przy zapisie do JPG przezroczystość
/// spłaszczana na białe tło (JPEG nie ma kanału alfa).
public enum ImageConverter {

    /// Konwertuje `input` do `target` (`.png` albo `.jpg`) i zapisuje w `outputDirectory`.
    /// `quality` (0…1) dotyczy wyłącznie JPG; PNG jest bezstratny.
    @discardableResult
    public static func convert(
        input: URL,
        to target: DocumentFormat,
        quality: Double = 0.9,
        outputDirectory: URL
    ) throws -> URL {
        guard target == .png || target == .jpg else {
            throw SkrybaError.unsupportedTarget(target.displayName)
        }
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              var cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw SkrybaError.documentReadFailed(input.lastPathComponent)
        }

        // Przestrzeń i alfę liczymy z ORYGINAŁU: wypalanie orientacji przez Core Image
        // dokłada kanał alfa i mogłoby fałszywie wyzwolić spłaszczanie.
        let space = rgbColorSpace(of: cg)
        let sourceHasAlpha = hasAlpha(cg)

        // Orientacja EXIF → pozycja pionowa (jak robi to `sips`/Podgląd), z zachowaniem gamutu.
        let orientation = orientation(of: src)
        if orientation != .up {
            cg = try oriented(cg, orientation, space: space)
        }
        // JPEG nie ma alfy: spłaszcz przezroczystość na biel (tylko gdy ŹRÓDŁO miało alfę),
        // w przestrzeni źródła, żeby nie zrzucić szerokiego gamutu do sRGB.
        if target == .jpg, sourceHasAlpha {
            cg = try flattenedOntoWhite(cg, space: space)
        }

        let outURL = try uniqueOutputURL(stem: input.deletingPathExtension().lastPathComponent,
                                         ext: target.fileExtension, in: outputDirectory)

        let utType = (target == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, utType, 1, nil) else {
            throw SkrybaError.documentReadFailed(outURL.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if target == .jpg {
            props[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, quality))
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SkrybaError.documentReadFailed(outURL.lastPathComponent)
        }
        return outURL
    }

    // MARK: - Pomocnicze

    /// Nazwa = nazwa źródła + nowe rozszerzenie; kolizja → `nazwa-2.ext` (bez nadpisania).
    private static func uniqueOutputURL(stem: String, ext: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    private static func orientation(of src: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }

    private static func hasAlpha(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }

    /// Przestrzeń barw źródła, o ile jest RGB (Display P3 / Adobe RGB / sRGB…).
    /// Dla przestrzeni innych niż RGB (np. skala szarości) zwraca sRGB jako bezpieczny domyślny.
    private static func rgbColorSpace(of cg: CGImage) -> CGColorSpace {
        if let cs = cg.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Wypala orientację EXIF w piksele (Core Image obsługuje wszystkie 8 wariantów),
    /// renderując w `space`, żeby nie zrzucić szerokiego gamutu do sRGB (domyślny CIContext klamruje).
    private static func oriented(_ cg: CGImage, _ orientation: CGImagePropertyOrientation, space: CGColorSpace) throws -> CGImage {
        let ci = CIImage(cgImage: cg).oriented(orientation)
        let ctx = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        guard let out = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space) else {
            throw SkrybaError.documentReadFailed("orientation")
        }
        return out
    }

    /// Rysuje obraz na nieprzezroczystym białym tle (usuwa kanał alfa dla JPEG) w przestrzeni `space`.
    /// Gdy `space` nie nadaje się na kontekst bitmapowy, spada na sRGB.
    private static func flattenedOntoWhite(_ cg: CGImage, space: CGColorSpace) throws -> CGImage {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { throw SkrybaError.documentReadFailed("flatten") }
        let bitmap = CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: bitmap)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: bitmap)
        guard let ctx else { throw SkrybaError.documentReadFailed("flatten") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw SkrybaError.documentReadFailed("flatten") }
        return out
    }
}
