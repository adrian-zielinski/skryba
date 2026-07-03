import Foundation
import AppKit
import PDFKit

/// Atrybut niosący poziom nagłówka (2, 3…) przez `NSAttributedString`. Eksporter
/// Markdown zamienia go na `##`/`###`; pozostałe eksportery po prostu go ignorują,
/// więc dodanie atrybutu nie wpływa na konwersje spoza PDF-a.
public extension NSAttributedString.Key {
    static let skrybaHeading = NSAttributedString.Key("skrybaHeading")
}

/// Wyciąganie czytelnego, ustrukturyzowanego tekstu z PDF-a.
///
/// Problem: dla graficznych raportów (karty, kolumny, pismo pozycjonowane glif po
/// glifie) `PDFDocument.string` bywa „posiekany” — jedno słowo rozpada się na kilka
/// fragmentów w osobnych liniach („A”/„ut”/„omat”/„yczna”). Taka warstwa tekstowa
/// jest długa, więc próg oparty na długości jej nie wykrywa, a naiwny zapis daje
/// enter po każdym fragmencie.
///
/// Rozwiązanie: dla każdej strony sprawdzamy, czy warstwa tekstowa jest posiekana
/// (dużo krótkich, bezspacyjnych fragmentów). Jeśli tak (albo strona jest skanem bez
/// tekstu) — czytamy stronę przez OCR, który widzi pełne linie. Następnie sklejamy
/// linie w akapity, wykrywamy nagłówki po rozmiarze pisma i usuwamy powtarzalną
/// stopkę/nagłówek strony.
public enum PDFExtractor {

    // MARK: - Model

    /// Linia wejściowa: tekst + współczynnik rozmiaru względem mediany strony
    /// (1.0 = przeciętne pismo; >1 = większe, kandydat na nagłówek).
    public struct Line: Sendable, Equatable {
        public var text: String
        public var sizeRatio: Double
        public init(text: String, sizeRatio: Double = 1.0) {
            self.text = text; self.sizeRatio = sizeRatio
        }
    }

    /// Blok wyjściowy: akapit (heading == 0) albo nagłówek danego poziomu.
    public struct Block: Sendable, Equatable {
        public var text: String
        public var heading: Int   // 0 = akapit, 2 = ##, 3 = ###
        public init(text: String, heading: Int = 0) {
            self.text = text; self.heading = heading
        }
    }

    // MARK: - Główne API (I/O)

    /// Buduje bogaty `NSAttributedString` (z nagłówkami) z PDF-a. Zwraca `nil`, gdy
    /// dokumentu nie da się otworzyć lub nie ma w nim żadnej treści — wtedy woła się
    /// dotychczasową ścieżkę awaryjną.
    static func attributed(from url: URL, shouldCancel: (() -> Bool)? = nil) -> NSAttributedString? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }

        var pages: [[Line]] = []
        for i in 0..<doc.pageCount {
            if shouldCancel?() == true { return nil }
            guard let page = doc.page(at: i) else { pages.append([]); continue }
            let raw = page.string ?? ""
            if needsOCR(pageString: raw) {
                pages.append(linesFromOCR(OCR.recognizePageLines(page)))
            } else {
                pages.append(linesFromLayer(raw))
            }
        }

        let cleaned = dropBoilerplate(pages)
        var blocks: [Block] = []
        for lines in cleaned { blocks.append(contentsOf: mergeParagraphs(lines)) }
        guard !blocks.isEmpty else { return nil }
        return render(blocks)
    }

    // MARK: - Detekcja posiekanej / pustej warstwy tekstowej

    /// Czy stronę trzeba przepuścić przez OCR: gdy warstwa tekstowa jest pusta/skąpa
    /// (skan) albo „posiekana” (dużo krótkich fragmentów bez spacji).
    public static func needsOCR(pageString: String) -> Bool {
        let trimmed = pageString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 12 { return true }               // skan / brak warstwy
        return isGarbledLayer(pageString)
    }

    /// Heurystyka „posiekanej” warstwy tekstowej. Odróżnia raport carVertical
    /// (fragmenty ~10 znaków, 45–62% bez spacji) od normalnego PDF-a (wiersze ~60
    /// znaków, ~0% bez spacji). Wymaga spełnienia obu warunków, by nie ruszać
    /// nietypowych, ale poprawnych stron.
    public static func isGarbledLayer(_ pageString: String) -> Bool {
        let lines = pageString
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 5 else { return false }
        let avgLength = Double(lines.reduce(0) { $0 + $1.count }) / Double(lines.count)
        let noSpace = lines.filter { !$0.contains(" ") }.count
        let noSpaceShare = Double(noSpace) / Double(lines.count)
        return avgLength < 25 && noSpaceShare > 0.35
    }

    // MARK: - Źródła linii

    /// Linie z (dobrej) warstwy tekstowej — bez informacji o rozmiarze pisma.
    static func linesFromLayer(_ pageString: String) -> [Line] {
        pageString
            .components(separatedBy: "\n")
            .map { Line(text: $0.trimmingCharacters(in: .whitespaces), sizeRatio: 1.0) }
            .filter { !$0.text.isEmpty }
    }

    /// Linie z OCR — rozmiar pisma wyrażamy jako stosunek do mediany wysokości na stronie.
    static func linesFromOCR(_ ocrLines: [OCR.Line]) -> [Line] {
        guard !ocrLines.isEmpty else { return [] }
        let heights = ocrLines.map { $0.heightPt }.sorted()
        let median = heights[heights.count / 2]
        guard median > 0 else { return ocrLines.map { Line(text: $0.text) } }
        return ocrLines.map { Line(text: $0.text, sizeRatio: Double($0.heightPt / median)) }
    }

    // MARK: - Usuwanie powtarzalnej stopki / nagłówka strony

    /// Usuwa linie powtarzające się na wielu stronach (logo, VIN, data, disclaimer).
    /// Klucz porównania pomija cyfry i interpunkcję, więc warianty tej samej stopki
    /// różniące się tylko datą/numerem strony scalają się w jedno. Treść różniąca się
    /// słowami ma inny klucz i zostaje. Działa tylko dla dłuższych dokumentów.
    public static func dropBoilerplate(_ pages: [[Line]]) -> [[Line]] {
        guard pages.count >= 4 else { return pages }
        // Na ilu RÓŻNYCH stronach występuje dany klucz linii.
        var pageHits: [String: Int] = [:]
        for lines in pages {
            for key in Set(lines.map { boilerplateKey($0.text) }) where !key.isEmpty {
                pageHits[key, default: 0] += 1
            }
        }
        let threshold = max(3, Int(ceil(Double(pages.count) * 0.4)))
        let boilerplate = Set(pageHits.filter { $0.value >= threshold }.keys)
        guard !boilerplate.isEmpty else { return pages }
        return pages.map { lines in
            lines.filter { line in
                let key = boilerplateKey(line.text)
                return key.isEmpty || !boilerplate.contains(key)
            }
        }
    }

    /// Klucz do wykrywania stopek: tylko litery (bez cyfr, dat, interpunkcji, znaków
    /// „|" wstawianych przez OCR), złożone w małe słowa. Pusty, gdy linia to same
    /// cyfry/symbole (np. „88") — takich nie traktujemy jako boilerplate.
    static func boilerplateKey(_ text: String) -> String {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.joined(separator: " ")
    }

    // MARK: - Sklejanie akapitów + wykrywanie nagłówków

    /// Zamienia linie w bloki: nagłówki (po rozmiarze) stoją osobno, a zwykłe linie
    /// łączą się w akapity, gdy następna jest kontynuacją poprzedniej.
    public static func mergeParagraphs(_ lines: [Line]) -> [Block] {
        var blocks: [Block] = []
        var buffer = ""

        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { blocks.append(Block(text: t, heading: 0)) }
            buffer = ""
        }

        for line in lines {
            let text = stripLeadingIconJunk(line.text)
            // Pomijamy pojedyncze znaki — to zwykle śmieci OCR z ikon, osi wykresów
            // czy punktorów, nie treść.
            guard text.count > 1 else { continue }

            let level = classifyHeading(text: text, sizeRatio: line.sizeRatio)
            if level > 0 {
                flush()
                blocks.append(Block(text: text, heading: level))
                continue
            }

            if buffer.isEmpty {
                buffer = text
            } else if shouldJoin(previous: buffer, next: text) {
                buffer += " " + text
            } else {
                flush()
                buffer = text
            }
        }
        flush()
        return blocks
    }

    /// Usuwa wiodące „śmieci" z OCR — piktogramy/ikony kafelków odczytane jako 1–3
    /// znaki zawierające symbol (np. „+* ", „o= ", „® ", „&* "), które poprzedzają
    /// właściwą treść. Zbiór symboli nie zawiera kropki/przecinka/nawiasu, więc nie
    /// rusza liczb („354", „6,4"), skrótów („np.") ani numeracji („1)").
    public static func stripLeadingIconJunk(_ text: String) -> String {
        let symbols = Set("+*=&®©™•·|~^°§‹›«»▪◦")
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        while let space = s.firstIndex(of: " ") {
            let token = s[s.startIndex..<space]
            guard token.count <= 3, token.contains(where: { symbols.contains($0) }) else { break }
            s = s[s.index(after: space)...].drop { $0 == " " }
        }
        return String(s).trimmingCharacters(in: .whitespaces)
    }

    /// Czy linię `next` dokleić do bieżącego akapitu (kontynuacja zawiniętego zdania).
    static func shouldJoin(previous: String, next: String) -> Bool {
        guard let last = previous.last(where: { !$0.isWhitespace }),
              let first = next.first(where: { !$0.isWhitespace }) else { return false }
        if ".!?:".contains(last) { return false }        // poprzednia kończy zdanie
        if "•·-–—*".contains(first) { return false }      // następna to punkt listy
        // Kontynuacją jest linia zaczynająca się małą literą (nowe zdania/etykiety
        // w tych raportach startują wielką literą lub liczbą).
        return first.isLowercase
    }

    /// Poziom nagłówka dla linii (0 = zwykły akapit). Sygnałem jest rozmiar pisma
    /// (z OCR), ale filtrujemy oczywiste nie-nagłówki: liczby, punkty listy, zdania.
    public static func classifyHeading(text: String, sizeRatio: Double) -> Int {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard sizeRatio >= 1.45 else { return 0 }
        guard t.count <= 60 else { return 0 }                       // za długie = zdanie
        guard t.contains(where: { $0.isLetter }) else { return 0 }  // sama liczba/„88”
        if let last = t.last, ".,;:•".contains(last) { return 0 }
        if let first = t.first, "•·-–—*".contains(first) { return 0 }
        if t.split(whereSeparator: { $0 == " " }).count > 6 { return 0 }  // dłuższe = zdanie, nie nagłówek
        return sizeRatio >= 1.8 ? 2 : 3
    }

    // MARK: - Budowa NSAttributedString

    private static func render(_ blocks: [Block]) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            var attrs: [NSAttributedString.Key: Any]
            switch block.heading {
            case 2:  attrs = [.font: NSFont.boldSystemFont(ofSize: 20), .skrybaHeading: 2]
            case 3:  attrs = [.font: NSFont.boldSystemFont(ofSize: 16), .skrybaHeading: 3]
            default: attrs = [.font: body]
            }
            out.append(NSAttributedString(string: block.text, attributes: attrs))
            if i < blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            }
        }
        return out
    }
}
