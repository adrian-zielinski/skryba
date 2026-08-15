---
kind: handoff-topic
topic: transkrypcja
status: in-progress
updated: 2026-08-15
---

# Transkrypcja: kopiowanie i start bez klikania

> Zakres: kolejka w zakładce transkrypcji (ContentView + AppModel). NIE obejmuje: konwersji dokumentów, Szybkich akcji Findera, edytora PDF.

## Aktualny stan
- ✅ Przy ukończonej pozycji: **Skopiuj transkrypcję**, **Skopiuj ścieżkę pliku** (też w menu kontekstowym).
- ✅ Na pasku, gdy na liście jest choć jedna gotowa transkrypcja: **Skopiuj wszystkie ścieżki**, **Skopiuj wszystkie transkrypcje**.
- ✅ Nowy plik (Dodaj / drop / folder) od razu startuje kolejkę; wrzucony w trakcie jedzie po bieżącym.
- 🔄 Kod w working tree, **niezacommitowany** (`AppModel.swift`, `ContentView.swift`). Build `swift build --target Skryba` przeszedł. Aplikacja nie była klikana.

## Kluczowe decyzje i ustalenia
- Ścieżka = plik transkrypcji (`outputURL`), nie nagranie — wklejka dla agenta AI.
- Zbiorcze ścieżki: jedna linia na plik. Zbiorcze treści: `/////` między plikami (`\n/////\n`), kolejność jak na liście.
- Kopiowane są tylko pozycje `done` z `outputURL` (to, co widać i da się odczytać).
- Auto-start: `addFiles` → `startIfIdle()`. Koniec kolejki bez cancel też woła `startIfIdle()`, żeby dogonić pliki dodane w trakcie. „Transkrybuj” zostaje na wznowienie po przerwie i ponowienie błędu.
- „Dodaj pliki” nie jest już wyłączane w trakcie przetwarzania.

## Następny krok
Potwierdzić UX w uruchomionej apce (jeden plik + kilka, kopiowanie pojedyncze i zbiorcze, drop w trakcie kolejki), potem commit kodu — dopiero po „wdrażaj” push.

## Czego NIE robić
- Nie kopiować ścieżki nagrania zamiast pliku wynikowego (linki tymczasowe i tak znikają po transkrypcji).
- Nie ruszać zakładki Konwersja tymi przyciskami.
- Nie pushować commita z `Sources/` bez zgody na wdrożenie.

## Artefakty
- [Sources/Skryba/AppModel.swift](Sources/Skryba/AppModel.swift) — `copyableJobs`, schowek, `startIfIdle`
- [Sources/Skryba/ContentView.swift](Sources/Skryba/ContentView.swift) — przyciski w wierszu i na pasku

## Dziennik sesji
- 2026-08-15 — kopiowanie per plik i zbiorcze (`/////`); transkrypcja startuje sama po dodaniu pliku.
