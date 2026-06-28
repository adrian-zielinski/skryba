#!/usr/bin/env bash
# Generuje Resources/AppIcon.icns (ikona aplikacji). Wymaga swift, sips, iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
MASTER="$TMP/master.png"

swift - "$MASTER" <<'SWIFT'
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: S, height: S)
let radius = S * 0.2237
let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
clip.addClip()

// Tło: gradient indygo → niebieski.
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.09, green: 0.11, blue: 0.32, alpha: 1),
    NSColor(srgbRed: 0.23, green: 0.45, blue: 0.96, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

// Delikatny rozbłysk u góry.
let glow = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.16),
    NSColor(white: 1, alpha: 0.0),
])!
glow.draw(in: NSRect(x: 0, y: S*0.55, width: S, height: S*0.45), angle: -90)

// Fala dźwiękowa: zaokrąglone słupki.
let heights: [CGFloat] = [0.34, 0.58, 0.86, 1.0, 0.72, 0.50, 0.66]
let n = heights.count
let groupW = S * 0.56
let gap = groupW / CGFloat(n)
let barW = gap * 0.5
let startX = (S - groupW) / 2 + (gap - barW) / 2
NSColor.white.setFill()
for i in 0..<n {
    let h = S * 0.40 * heights[i]
    let x = startX + CGFloat(i) * gap
    let y = (S - h) / 2
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                           xRadius: barW/2, yRadius: barW/2)
    bar.fill()
}

img.unlockFocus()
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render fail\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("master OK")
SWIFT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/icon_$name.png" >/dev/null
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "▸ Gotowe: $ROOT/Resources/AppIcon.icns"
ls -la "$ROOT/Resources/AppIcon.icns"
rm -rf "$TMP"
