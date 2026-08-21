---
kind: handoff-topic
topic: transkrypcja
status: in-progress
updated: 2026-08-21
---

# Transkrypcja: kolejka, kopiowanie, oś czasu

> Zakres: kolejka w zakładce transkrypcji (ContentView + AppModel + OutputWriter + CLI). NIE obejmuje: konwersji dokumentów, Szybkich akcji Findera, edytora PDF.

## Aktualny stan
- ✅ Przy ukończonej pozycji: **Skopiuj transkrypcję**, **Skopiuj ścieżkę pliku** (też w menu kontekstowym).
- ✅ Na pasku, gdy na liście jest choć jedna gotowa transkrypcja: **Skopiuj wszystkie ścieżki**, **Skopiuj wszystkie transkrypcje**.
- ✅ Nowy plik (Dodaj / drop / folder) od razu startuje kolejkę; wrzucony w trakcie jedzie po bieżącym.
- ✅ Checkbox **Znaczniki czasu** na pasku transkrypcji (obok formatu). W `.md`/`.txt` każda wypowiedź dostaje prefiks osi YouTube: `[0:12]`, `[1:03:45]`. SRT/VTT — checkbox szary (mają czasy same). UserDefaults `includeTimestamps`; CLI `--timestamps`.
- ✅ Testy `swift run skryba-tests`: 245 OK. `bash Scripts/build-app.sh` z 2026-08-21, nowa `build/Skryba.app` odpalona (stara paczka z lipca nie miała checkboxa).
- 🔄 Kod źródłowy **niezacommitowany** (kopiowanie z 15.08 + oś czasu z 21.08). Paczka `.app` jest w `build/`, nie w gicie.

## Kluczowe decyzje i ustalenia
- Ścieżka = plik transkrypcji (`outputURL`), nie nagranie — wklejka dla agenta AI.
- Zbiorcze ścieżki: jedna linia na plik. Zbiorcze treści: `/////` między plikami (`\n/////\n`), kolejność jak na liście.
- Kopiowane są tylko pozycje `done` z `outputURL` (to, co widać i da się odczytać).
- Auto-start: `addFiles` → `startIfIdle()`. Koniec kolejki bez cancel też woła `startIfIdle()`, żeby dogonić pliki dodane w trakcie. „Transkrybuj” zostaje na wznowienie po przerwie i ponowienie błędu.
- „Dodaj pliki” nie jest już wyłączane w trakcie przetwarzania.
- Znaczniki to **oś wypowiedzi**, nie rozdziały YouTube. Cel: wrzucić transkrypcję do innego AI, które zrobi rozdziały. Segment whisper (zdanie), czas startu, bez końca. Format: `< 1 h` → `m:ss` (minuty bez zera), `≥ 1 h` → `h:mm:ss`. Podłoga do sekundy (`1.5` → `0:01`).
- User odpala **`build/Skryba.app`**, nie produkt `swift build --target Skryba`. Po zmianie UI trzeba `bash Scripts/build-app.sh`.

## Następny krok
Potwierdzić w odpalonej apce checkbox **Znaczniki czasu** (Markdown → zaznacz → transkrypcja z `[m:ss]`; SRT → szary). Przy okazji: kopiowanie pojedyncze/zbiorcze i auto-start z 15.08. Potem commit `Sources/` — dopiero po „wdrażaj” push.

## Czego NIE robić
- Nie kopiować ścieżki nagrania zamiast pliku wynikowego (linki tymczasowe i tak znikają po transkrypcji).
- Nie ruszać zakładki Konwersja tymi przyciskami.
- Nie pushować commita z `Sources/` bez zgody na wdrożenie.
- Nie kończyć na `swift build --target Skryba` — to nie aktualizuje `.app`, którą user klika.
- Nie wkładać timestampów do SRT/VTT (własny format). Nie robić rozdziałów w Skrybie — tylko oś zdań.

## Artefakty
- [Sources/Skryba/AppModel.swift](Sources/Skryba/AppModel.swift) — `copyableJobs`, schowek, `startIfIdle`, `includeTimestamps`
- [Sources/Skryba/ContentView.swift](Sources/Skryba/ContentView.swift) — przyciski kopiowania, checkbox „Znaczniki czasu”
- [Sources/SkrybaKit/OutputWriter.swift](Sources/SkrybaKit/OutputWriter.swift) — `timestamps`, `timelineStamp`
- [Sources/SkrybaKit/Transcriber.swift](Sources/SkrybaKit/Transcriber.swift) — parametr `timestamps`
- [Sources/skryba-cli/main.swift](Sources/skryba-cli/main.swift) — `--timestamps`
- [Sources/skryba-tests/main.swift](Sources/skryba-tests/main.swift) — testy osi
- [README.md](README.md) — wzmianka o znacznikach
- [Scripts/build-app.sh](Scripts/build-app.sh) — składa `build/Skryba.app`

## Dziennik sesji
- 2026-08-21 — checkbox osi czasu w md/txt (`[m:ss]` / `[h:mm:ss]`); przebudowana `build/Skryba.app`.
- 2026-08-15 — kopiowanie per plik i zbiorcze (`/////`); transkrypcja startuje sama po dodaniu pliku.
