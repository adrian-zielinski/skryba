# Skryba — projekt

Data: 2026-06-29

## Cel

Natywna aplikacja macOS, do której wrzucasz pliki audio/wideo i dostajesz transkrypcje w wyznaczonym folderze. Program ma być publikowalny na GitHubie tak, by inni mogli go pobrać i uruchomić. Częścią wymagania jest doradzanie, który model wybrać.

## Decyzje

- **Technologia:** natywny SwiftUI + Swift Package Manager. Buduje się też pod samym Command Line Tools (bez pełnego Xcode), więc próg wejścia jest niski.
- **Silnik:** whisper.cpp v1.9.1 wpięty jako prebuilt `whisper.xcframework` (slice macOS, arm64+x86_64). Metal jest w środku, więc GPU działa w runtime bez kompilatora Metala na maszynie budującej. xcframework leży w repo (5,5 MB), bez pobierania przy buildzie.
- **Dekodowanie audio:** AVFoundation. Pokrywa natywnie `m4a`, `mp3`, `wav`, `aac`, `aiff`, `mov`, `mp4`. Dla rzadszych formatów (`ogg`/`opus`, `flac`, `webm`, `mkv`) program używa systemowego `ffmpeg`, jeśli jest. Dzięki temu bundel nie wozi binarki ffmpeg (mniejszy, bez kłopotów licencyjnych).
- **Dystrybucja:** niepodpisana aplikacja z GitHub Releases. Pierwsze uruchomienie przez prawy przycisk → Otwórz. Podpis ad-hoc, żeby działała na Apple Silicon.
- **Modele:** pobierane na żądanie z Hugging Face do Application Support. Nie trafiają do repo (są duże).

## Moduły

- `AudioDecoder` — plik → 16 kHz mono Float32 (AVFoundation, odwrót na ffmpeg).
- `WhisperEngine` — opakowanie C-API whisper.cpp: ładuje model, transkrybuje próbki, zwraca segmenty z czasami.
- `ModelCatalog` / `ModelStore` — lista modeli z metadanymi i rekomendacją; pobieranie z postępem, usuwanie.
- `OutputWriter` — render i zapis `.md`/`.txt`/`.srt`/`.vtt`.
- `Transcriber` — spina dekoder, silnik i zapis; trzyma jeden wczytany model dla wielu plików.
- `Skryba` (SwiftUI) — drag&drop, kolejka sekwencyjna z postępem, menedżer modeli, ustawienia.
- `skryba-cli` — to samo z wiersza poleceń.
- `skryba-tests` — runner testów działający bez XCTest (którego brak pod CLT).

## Co świadomie pominięto

Edycja transkrypcji w aplikacji, diaryzacja mówców, chmura, Windows/Linux, App Store. Można dołożyć później.

## Stan

Zrealizowane i przetestowane: rdzeń, CLI, aplikacja, pakowanie do `.app`/`.zip`. Testy (32 asercje, w tym pełny e2e na silniku) przechodzą. Transkrypcja realnego nagrania działa z akceleracją Metal.
