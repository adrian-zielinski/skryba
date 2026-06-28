#!/usr/bin/env bash
# Buduje Skryba.app — samodzielny bundel z wkompilowanym frameworkiem whisper —
# oraz Skryba.zip gotowy do dystrybucji. Wymaga tylko Swift toolchain (CLT wystarczą).
#
# Składanie i podpis odbywają się w katalogu tymczasowym poza iCloud, bo atrybuty
# iCloud (com.apple.fileprovider.*) psują podpis kodu.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Skryba"
BUNDLE_ID="pl.zielinski.skryba"
VERSION="1.0.0"
OUT_DIR="$ROOT/build"
STAGE="$(mktemp -d)/$APP_NAME.app"

echo "▸ Kompilacja (release)..."
swift build -c release --product skryba

BIN_DIR="$(swift build -c release --product skryba --show-bin-path)"
EXECUTABLE="$BIN_DIR/skryba"
[ -f "$EXECUTABLE" ] || { echo "BŁĄD: brak binarki: $EXECUTABLE"; exit 1; }

echo "▸ Składanie bundla (staging poza iCloud)..."
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$EXECUTABLE" "$STAGE/Contents/MacOS/$APP_NAME"
cp -R "$ROOT/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework" \
      "$STAGE/Contents/Frameworks/whisper.framework"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    ICON_KEY=""
fi

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>MIT. whisper.cpp © Georgi Gerganov (MIT).</string>
    $ICON_KEY
</dict>
</plist>
PLIST

echo "▸ rpath do frameworka + czyszczenie atrybutów..."
install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
xattr -cr "$STAGE"
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

echo "▸ Podpis ad-hoc..."
codesign --force --sign - "$STAGE/Contents/Frameworks/whisper.framework"
codesign --force --sign - "$STAGE"

echo "▸ Weryfikacja podpisu..."
codesign --verify --deep --strict "$STAGE" && echo "  podpis OK"

echo "▸ Pakowanie do $OUT_DIR ..."
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/$APP_NAME.app" "$OUT_DIR/$APP_NAME.zip"
ditto "$STAGE" "$OUT_DIR/$APP_NAME.app"
ditto -c -k --keepParent "$STAGE" "$OUT_DIR/$APP_NAME.zip"
rm -rf "$(dirname "$STAGE")"

echo "▸ Gotowe:"
echo "    $OUT_DIR/$APP_NAME.app   (do uruchomienia lokalnie)"
echo "    $OUT_DIR/$APP_NAME.zip   (do wrzucenia na GitHub Releases)"
du -sh "$OUT_DIR/$APP_NAME.zip"
