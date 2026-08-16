---
kind: handoff-topic
topic: konwersja-obrazow
status: done
updated: 2026-08-17
---

# Konwersja obrazów: PNG/zdjęcie → WebP albo PDF 1:1

> Zakres: zakładka Konwersja, `ImageConverter`, CLI `image`, Szybkie akcje Findera — cele **WebP lossless** i **PDF-obraz 1:1**. NIE obejmuje: kolejki transkrypcji (→ transkrypcja.md), edytora PDF, OCR do txt/md/docx.

## Aktualny stan
- ✅ PNG (i inne obrazy czytane przez ImageIO) → **WebP** bezstratnie (`exact=1`, te same piksele, alfa).
- ✅ Obraz → **PDF 1:1**: jedna strona = cały obraz, 1 px = 1 pt, Flate (nie JPEG), alfa jako `/SMask`.
- ✅ GUI: cele w pickerze; przy WebP / PDF-z-obrazu etykieta „1:1 bezstratnie”.
- ✅ CLI: `skryba-cli image --to webp|pdf`.
- ✅ Finder: dwie nowe akcje (WebP, PDF). `isInstalled` wymaga **czterech** bundli — stary zestaw JPG+PNG pokaże „Zainstaluj”.
- ✅ Testy: `swift run skryba-tests` — 228 zaliczonych (w tym piksele WebP i PDF 1:1).
- 🔄 Kod **niezacommitowany** (working tree + nowy `Vendor/libwebp`, `ImageWebP.swift`, `ImagePDF.swift`). Apka z `build/` nie przebudowana tymi zmianami.

## Kluczowe decyzje i ustalenia
- **Obraz → PDF to raster 1:1, nie OCR.** Dawniej PNG+cel PDF szło przez OCR i `PDFRenderer` (tekst na A4). Teraz `DocumentConverter` zrzuca `source.category == .image && target == .pdf` do `ImageConverter`. OCR zostaje przy md/txt/docx/….
- **ImageIO/sips nie zapisują WebP** (`HAS WEBP DEST: false`). Enkoder: vendored **libwebp 1.6.0** (`Vendor/libwebp`, target `CWebP`), `WebPConfig.exact = 1` (RGB pod przezroczystością nietknięty).
- **PDF nie przez `PDFPage(image:)` ani `CGContext.draw` do PDF** — CG bywa wciska JPEG. Własny PDF 1.4 + obraz Flate + opcjonalny SMask/ICC.
- **`NSData.compressed(using: .zlib)` to surowy deflate**, nie RFC 1950. PDF `/FlateDecode` wymaga `compress2` z `import zlib` (nagłówek 0x78…). Inaczej strona jest pusta (magenta/biała przy renderze).
- **ICC tylko szeroki gamut** (P3 / Adobe / ProPhoto / 2020). DeviceRGB/sRGB → `/DeviceRGB` bez profilu — inaczej PDFKit konwertuje kolory i „1:1” się sypie.
- SMask tylko gdy naprawdę jest piksel `alpha < 255`.

## Następny krok
Commit kodu konwersji (nie tylko HANDOFF) po „wdrażaj”; ewentualnie `bash Scripts/build-app.sh` i ponowne **Zainstaluj w Finderze**, żeby CLI w `.app` umiało `--to webp|pdf`.

## Czego NIE robić
- Nie wracać obraz→PDF na ścieżkę OCR / `PDFRenderer`.
- Nie pisać WebP przez ImageIO/`sips`.
- Nie używać `NSData.compressed(.zlib)` do strumieni PDF.
- Nie doklejać ICC do DeviceRGB/sRGB „dla kompletności”.
- Nie pushować commita z `Sources/` / `Vendor/` bez „wdrażaj”.
- W `Package.swift` targetu `CWebP` trzymać `exclude` na Makefile.am / `.pc.in` / `.rc` — SwiftPM próbuje je kompilować.

## Artefakty
- [Sources/SkrybaKit/ImageConverter.swift](Sources/SkrybaKit/ImageConverter.swift) — routing png/jpg/webp/pdf, raster RGBA
- [Sources/SkrybaKit/ImageWebP.swift](Sources/SkrybaKit/ImageWebP.swift) — mostek do `CWebP`
- [Sources/SkrybaKit/ImagePDF.swift](Sources/SkrybaKit/ImagePDF.swift) — PDF 1:1 + `compress2`
- [Sources/SkrybaKit/DocumentConverter.swift](Sources/SkrybaKit/DocumentConverter.swift) — obraz→PDF nie idzie w OCR
- [Sources/SkrybaKit/DocumentFormat.swift](Sources/SkrybaKit/DocumentFormat.swift) — cel `.webp`
- [Sources/Skryba/ConversionView.swift](Sources/Skryba/ConversionView.swift) / [ConversionModel.swift](Sources/Skryba/ConversionModel.swift) — UI + komunikat Findera
- [Sources/skryba-cli/main.swift](Sources/skryba-cli/main.swift) — `--to webp|pdf`
- [Sources/SkrybaKit/FinderQuickAction.swift](Sources/SkrybaKit/FinderQuickAction.swift) — 4 akcje
- [Sources/skryba-tests/main.swift](Sources/skryba-tests/main.swift) — testy 1:1 i Findera
- [Vendor/libwebp/](Vendor/libwebp/) — libwebp 1.6.0 (`src/` + `sharpyuv/` + shim)
- [Package.swift](Package.swift) — target `CWebP`
- [NOTICE](NOTICE) / [README.md](README.md) — licencja i opis
- [docs/superpowers/specs/2026-07-06-konwersja-obrazow-design.md](docs/superpowers/specs/2026-07-06-konwersja-obrazow-design.md) — spec zaktualizowany o WebP/PDF

## Dziennik sesji
- 2026-08-17 — cele WebP lossless i PDF-obraz 1:1; libwebp w Vendor; Flate przez `compress2`; testy 228/0.
