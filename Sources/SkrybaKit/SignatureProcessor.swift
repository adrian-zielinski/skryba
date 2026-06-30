import Foundation
import AppKit

/// Przygotowanie podpisów: wycięcie białego tła (zdjęcie z kartki → przezroczysty
/// podpis), render narysowanego podpisu oraz konwersja do PNG.
public enum SignatureProcessor {

    /// Usuwa jasne tło (białą kartkę), zostawiając sam podpis z przezroczystością.
    /// Zachowuje kolor tuszu; krawędzie zostają wygładzone (alfa z jasności).
    /// Wynik jest przycięty do zawartości.
    public static func removeBackground(_ input: NSImage,
                                        whiteThreshold: CGFloat = 0.72,
                                        gain: CGFloat = 1.4) -> NSImage? {
        guard let cg = input.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = CGFloat(pixels[i]) / 255
                let g = CGFloat(pixels[i + 1]) / 255
                let b = CGFloat(pixels[i + 2]) / 255
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                var alpha: CGFloat = lum >= whiteThreshold ? 0 : min(1, (whiteThreshold - lum) / whiteThreshold * gain)
                if alpha < 0.08 { alpha = 0 }
                let a8 = UInt8((alpha * 255).rounded())
                pixels[i]     = UInt8((r * alpha * 255).rounded())   // premultiplied
                pixels[i + 1] = UInt8((g * alpha * 255).rounded())
                pixels[i + 2] = UInt8((b * alpha * 255).rounded())
                pixels[i + 3] = a8
                if a8 > 0 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard let output = ctx.makeImage() else { return nil }

        // Przytnij do zawartości (z marginesem).
        if maxX >= minX, maxY >= minY {
            let pad = 8
            let cropX = max(0, minX - pad)
            let cropY = max(0, minY - pad)
            let cropW = min(width - cropX, maxX - minX + 1 + 2 * pad)
            let cropH = min(height - cropY, maxY - minY + 1 + 2 * pad)
            if let cropped = output.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) {
                return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            }
        }
        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
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
