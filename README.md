# Skryba

Transkrypcja audio i wideo na Macu, w całości lokalnie. Przeciągasz pliki, wybierasz folder, dostajesz tekst. Nic nie wychodzi do internetu.

Skryba używa [whisper.cpp](https://github.com/ggml-org/whisper.cpp) z akceleracją Metal (GPU), więc godzina nagrania liczy się kilka minut. Obsługuje wsady wielu plików i przetwarza je po kolei.

> **English:** A native macOS app for fully local audio/video transcription. Drag files in, pick an output folder, get text out. Powered by whisper.cpp with Metal acceleration. Scroll down for the [English section](#english).

---

## Co potrafi

- **Przeciągnij i upuść** pojedyncze pliki lub całe foldery.
- **Kolejka sekwencyjna** z paskiem postępu dla każdego pliku.
- **Wybór modelu** z wbudowaną legendą (od `tiny` po `large-v3-turbo`), pobieranie na żądanie.
- **Formaty wyjścia**: Markdown (`.md`), tekst (`.txt`), napisy `.srt` i `.vtt`.
- **Język**: automatyczne wykrywanie albo wskazany ręcznie (polski, angielski i dziesiątki innych).
- **Bez chmury, bez konta, bez Homebrew.** Cały silnik jest w aplikacji.

## Który model wybrać

Większy model daje lepszą jakość, ale działa wolniej i waży więcej. Dla polskiego i długich nagrań wybierz **Large v3 Turbo**: jakość najlepszego modelu przy prędkości średniego.

| Model | Rozmiar | Szybkość | Jakość | Kiedy używać |
|---|---|---|---|---|
| `tiny` | ~75 MB | ★★★★★ | ★☆☆☆☆ | Szybki szkic, krótkie notatki, słaby sprzęt |
| `base` | ~142 MB | ★★★★☆ | ★★☆☆☆ | Szybko i akceptowalnie |
| `small` | ~466 MB | ★★★☆☆ | ★★★☆☆ | Rozsądny kompromis dla wielu języków |
| `medium` | ~1,5 GB | ★★☆☆☆ | ★★★★☆ | Wysoka jakość, trudniejsze audio |
| `large-v3` | ~3,1 GB | ★☆☆☆☆ | ★★★★★ | Maksymalna dokładność, najwolniejszy |
| **`large-v3-turbo`** | ~1,6 GB | ★★★★☆ | ★★★★★ | **Domyślny.** Długie nagrania, polski |
| `large-v3-turbo-q5_0` | ~1,1 GB | ★★★★☆ | ★★★★★ | Jak turbo, mniej miejsca i RAM-u |

Wskazówki:
- Treść po angielsku? Warianty `.en` (`tiny.en`, `base.en`, `small.en`) są mniejsze i szybsze.
- Polski lub inne języki? Bierz `large-v3-turbo`. Małe modele gubią diakrytykę.
- Pierwsza transkrypcja pobiera wybrany model raz; potem działa offline.

## Instalacja

1. Pobierz `Skryba.zip` z zakładki [Releases](../../releases) i rozpakuj.
2. Przenieś `Skryba.app` do folderu Programy.
3. Przy pierwszym uruchomieniu kliknij aplikację **prawym przyciskiem → Otwórz**, potem **Otwórz** w oknie ostrzeżenia.

Ten jeden raz prawym przyciskiem jest potrzebny, bo aplikacja nie ma płatnego podpisu Apple. To zwykła aplikacja open source, a kod masz w tym repo. Później otwierasz ją normalnie.

## Jak używać

1. Przeciągnij pliki audio/wideo na okno (albo „Dodaj pliki").
2. Wybierz model, język i format. Ustaw folder docelowy (przycisk na dole).
3. Kliknij **Transkrybuj**. Pliki przetworzą się po kolei, każdy zapisze się pod swoją nazwą.

Wynik trafia do wybranego folderu jako `nazwa-nagrania.md` (albo `.txt`/`.srt`/`.vtt`).

## Wiersz poleceń

W paczce jest też `skryba-cli` dla pracy wsadowej i skryptów:

```bash
skryba-cli --out transkrypcje --lang pl nagranie.m4a folder/z/nagraniami
skryba-cli --list-models          # legenda modeli
skryba-cli --model-id small --format srt wywiad.mp4
skryba-cli --model /sciezka/do/ggml-large-v3-turbo.bin nagranie.mov
```

## Budowanie ze źródeł

Wymaga Swift 6 (Command Line Tools wystarczą, pełny Xcode nie jest konieczny).

```bash
git clone <repo>
cd Skryba
swift run skryba-tests        # testy
bash Scripts/build-app.sh      # zbuduj Skryba.app i Skryba.zip w build/
swift run skryba-cli --help    # albo od razu CLI
```

Możesz też otworzyć `Package.swift` w Xcode i uruchomić schemat `skryba`.

## Jak to działa

- **Silnik:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.1, wkompilowany jako framework z akceleracją Metal. Działa na GPU Apple Silicon, z odwrotem na CPU.
- **Dekodowanie audio:** AVFoundation (wbudowane w macOS), więc `m4a`, `mp3`, `wav`, `aac`, `mov`, `mp4` i inne czytają się natywnie, bez ffmpeg.
- **Formaty rzadsze** (`ogg`/`opus`, `flac`, `webm`, `mkv`): jeśli masz w systemie `ffmpeg`, Skryba użyje go jako odwrotu.
- **Prywatność:** żaden plik ani fragment audio nie opuszcza komputera. Pobierane są tylko modele (raz, z Hugging Face).

## Architektura

```
Sources/
  SkrybaKit/      rdzeń: dekoder audio, silnik whisper, katalog/pobieranie modeli, zapis
  Skryba/         aplikacja SwiftUI (drag&drop, kolejka, menedżer modeli)
  skryba-cli/     narzędzie wiersza poleceń
  skryba-tests/   runner testów (działa bez Xcode)
Frameworks/
  whisper.xcframework   silnik whisper.cpp (Metal), macOS arm64+x86_64
```

## Licencja

MIT. Zobacz [LICENSE](LICENSE).

Skryba zawiera [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (© Georgi Gerganov, licencja MIT). Modele Whisper pochodzą z [Hugging Face](https://huggingface.co/ggml-org/whisper.cpp). Szczegóły w [NOTICE](NOTICE).

---

<a name="english"></a>

# Skryba (English)

A native macOS app that transcribes audio and video entirely on your machine. Drag files in, pick an output folder, get text out. No cloud, no account, no Homebrew. The whisper.cpp engine ships inside the app and runs on the Apple Silicon GPU through Metal.

## Features

- Drag and drop single files or whole folders.
- Sequential queue with per-file progress.
- Model picker with a built-in guide, downloaded on demand.
- Output as Markdown, plain text, `.srt` or `.vtt` subtitles.
- Automatic language detection or a manual choice.

## Which model

Bigger means more accurate but slower and heavier. For most work, pick **Large v3 Turbo**: top-tier quality at mid-tier speed. English-only content runs faster on the `.en` variants. See the table in the Polish section above.

## Install

Download `Skryba.zip` from [Releases](../../releases), unzip, move `Skryba.app` to Applications. On first launch, **right-click the app and choose Open**, then **Open** in the dialog. This one step is needed because the app has no paid Apple signature. It is open source and the code is in this repo.

## Build from source

Needs Swift 6 (Command Line Tools are enough, full Xcode optional):

```bash
swift run skryba-tests       # tests
bash Scripts/build-app.sh     # builds build/Skryba.app and build/Skryba.zip
swift run skryba-cli --help
```

## License

MIT. Bundles whisper.cpp (© Georgi Gerganov, MIT). See [LICENSE](LICENSE) and [NOTICE](NOTICE).
