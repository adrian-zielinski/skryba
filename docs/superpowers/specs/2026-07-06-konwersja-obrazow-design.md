# Konwersja obrazów (JPG/PNG) + Szybkie akcje Findera

Data: 2026-07-06
Status: zatwierdzony do wdrożenia

## Cel

Dodać do Skryby dwie rzeczy:

1. **Konwersję obrazów do JPG lub PNG** w istniejącej zakładce „Konwersja".
   Wejście: dowolny obraz czytany przez macOS (DNG i inne RAW-y, HEIC/HEIF, JPG,
   PNG, TIFF, GIF, BMP, WebP). Wyjście: **JPG** (z regulowaną jakością) lub **PNG**.
2. **Szybkie akcje Findera** — „Konwertuj na JPG (Skryba)" i „Konwertuj na PNG
   (Skryba)" w menu prawego przycisku, działające **bez otwierania aplikacji**,
   zapisujące wynik **obok oryginału**.

Motywacja: użytkownik ma zdjęcia z iPhone'a (ProRAW `.DNG`, `.HEIC`), które
chce szybko zamieniać na uniwersalne JPG/PNG — najlepiej wprost z Findera.

## Ustalenia (decyzje użytkownika)

- Cele: **JPG i PNG** (nie więcej na tym etapie).
- Akcja Findera zapisuje **obok oryginału**, od razu, bez okien. Kolizja nazw → sufiks `-2`.
- Domyślna jakość JPG: **~90%**. Suwak w aplikacji; w akcji Findera wartość stała (90%).
- Instalacja akcji: **przycisk w aplikacji** („Zainstaluj akcje Findera").

## Architektura

Silnik natywny (ImageIO / Core Graphics), zero zewnętrznych zależności — potwierdzone
na realnym pliku DNG (48 Mpix ProRAW: DNG→JPG ~2 s/6 MB, DNG→PNG ~9 s/148 MB).

### 1. `SkrybaKit/ImageConverter.swift` (nowy)

Jedno źródło prawdy dla obu ścieżek (aplikacja i CLI/akcja Findera).

```
public enum ImageConverter {
    public static func convert(
        input: URL,
        to target: DocumentFormat,     // .png albo .jpg
        quality: Double = 0.9,         // JPEG 0...1; PNG ignoruje
        outputDirectory: URL
    ) throws -> URL
}
```

Zasady:
- Pełna rozdzielczość przez `CGImageSource` (RAW dekoduje się do pełnego obrazu na indeksie 0).
- **Orientacja EXIF wypalana w piksele** (odczyt `kCGImagePropertyOrientation`, transformacja
  do pozycji pionowej), żeby wynik nie był obrócony — tak jak robi `sips`.
- **PNG→JPG z przezroczystością**: spłaszczenie na białe tło (JPEG nie ma kanału alfa).
  Gdy źródło nie ma alfy, pomijamy spłaszczanie (wydajność).
- **PNG** zachowuje kanał alfa.
- Nazwa wyniku = nazwa źródła + nowe rozszerzenie; kolizja → `-nazwa-2.ext` (jak `OutputWriter`/`DocumentConverter`).

### 2. `SkrybaKit/DocumentFormat.swift` (zmiana)

- Nowe przypadki: `.png`, `.jpg` (kategoria `.image`, `nativeWritable = true`) — używane jako **cele**.
- `detect(_:)` bez zmian: pliki obrazów nadal wykrywane jako `.image` (źródło do OCR i do konwersji).
- `targets(for:)`: cele obrazowe (`.png`/`.jpg`) dostępne **tylko** gdy źródło jest obrazem
  (`source.category == .image`). Źródła tekstowe nie dostają celów obrazowych. Źródło-obraz
  nadal oferuje cele tekstowe (OCR) **oraz** JPG/PNG.

### 3. `SkrybaKit/DocumentConverter.swift` (zmiana)

- Nowy parametr `imageQuality: Double = 0.9` w `convert(...)`.
- Rozgałęzienie na początku: jeśli `source.category == .image && target.category == .image`
  → deleguj do `ImageConverter.convert(...)` (pomijając ścieżkę OCR/`NSAttributedString`).

### 4. `skryba-cli` (zmiana)

Nowy podtryb obrazów, wołany przez akcję Findera:

```
skryba-cli image --to png|jpg [--quality 90] [--beside-source | --out DIR] PLIK [PLIK...]
```

- `--beside-source`: zapis obok oryginału (domyślne dla akcji Findera).
- `--out DIR`: zapis do wskazanego folderu.
- Nie dotyka silnika whisper (image mode wychodzi wcześniej).

### 5. Szybkie akcje Findera

`SkrybaKit/FinderQuickAction.swift` (logika, testowalna, przyjmuje ścieżkę CLI jako parametr)
+ wywołanie z GUI (ścieżka z `Bundle.main`).

- Generuje dwa bundle `*.workflow` w `~/Library/Services/`:
  „Konwertuj na JPG (Skryba).workflow" i „…PNG…".
- Każdy zawiera `Contents/Info.plist` (`NSServices`, `NSSendFileTypes` = `public.image`,
  menu = nazwa akcji) oraz `document.wflow` (akcja „Run Shell Script" wołająca osadzony
  `skryba-cli image --to <fmt> --beside-source "$@"`).
- Ścieżka do CLI wpisywana **w chwili instalacji** (absolutna ścieżka z bundla aplikacji).
- Po zapisie: odświeżenie usług (`/System/Library/CoreServices/pbs -flush`).
- Odinstalowanie: usuwa oba bundle.

### 6. Pakowanie — `Scripts/build-app.sh` (zmiana)

- Zbuduj i osadź `skryba-cli` w `Skryba.app/Contents/MacOS/skryba-cli`
  (ten sam rpath `@executable_path/../Frameworks`), podpis ad-hoc.

### 7. GUI — `ConversionView.swift` / `ConversionModel.swift` (zmiana)

- Suwak/pole „Jakość JPG" widoczne, gdy cel = JPG (domyślnie 90%, zapamiętywane).
- Przycisk „Zainstaluj akcje Findera" (np. w pasku narzędzi zakładki lub małym menu).

## Testy (`skryba-tests`)

Nowa sekcja „Konwersja obrazów" (obrazy generowane w kodzie, jak istniejąca sekcja OCR):
- `targets(for: .image)` zawiera `png` i `jpg`; `targets(for: .md)` ich **nie** zawiera.
- PNG→JPG i JPG→PNG: plik powstał, poprawny typ (UTType), wymiary zachowane.
- Jakość JPG respektowana (niższa jakość → mniejszy plik na obrazie z gradientem).
- PNG z przezroczystością → JPG: wynik nieprzezroczysty, tło białe (róg ≈ biały).
- Orientacja: JPEG z tagiem `orientation=6` (piksele 100×40) → po konwersji obraz pionowy 40×100.
- Kolizja nazw: druga konwersja tego samego celu → sufiks `-2`.
- Opcjonalny E2E: `SKRYBA_IMG_TEST=ścieżka` konwertuje realny plik (np. DNG) i sprawdza wynik.

## Świadome ograniczenia

- Cele tylko JPG/PNG (HEIC/TIFF/WebP jako cele — ewentualnie później).
- PNG z 48 Mpix zdjęcia jest duży (~150 MB) — to natura formatu; JPG rekomendowany do zdjęć.
- Akcje pojawiają się w podmenu „Szybkie akcje" (o kolejności menu decyduje Finder).
- Przy pierwszym użyciu macOS może raz poprosić o dostęp do folderu (TCC) — jednorazowo.
- Aplikacja jest podpisana ad-hoc (open source) — Gatekeeper wymaga jednorazowego „Otwórz".
