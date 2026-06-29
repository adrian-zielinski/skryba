import Foundation
import AppKit

/// Lekka konwersja Markdown ⇄ tekst bogaty, na potrzeby konwertera dokumentów.
enum Markdown {

    // MARK: - Markdown → HTML (do wczytania jako NSAttributedString)

    static func toHTML(_ markdown: String) -> String {
        var html = "<html><body>"
        var inCodeBlock = false
        var listType: String? = nil   // "ul" lub "ol"

        func closeList() {
            if let lt = listType { html += "</\(lt)>"; listType = nil }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine

            // Bloki kodu ```
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock { html += "</code></pre>"; inCodeBlock = false }
                else { closeList(); html += "<pre><code>"; inCodeBlock = true }
                continue
            }
            if inCodeBlock {
                html += escape(line) + "\n"
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                closeList()
                continue
            }

            // Nagłówki
            if let (level, rest) = heading(trimmed) {
                closeList()
                html += "<h\(level)>\(inline(rest))</h\(level)>"
                continue
            }

            // Listy nieuporządkowane
            if let item = unorderedItem(trimmed) {
                if listType != "ul" { closeList(); html += "<ul>"; listType = "ul" }
                html += "<li>\(inline(item))</li>"
                continue
            }
            // Listy uporządkowane
            if let item = orderedItem(trimmed) {
                if listType != "ol" { closeList(); html += "<ol>"; listType = "ol" }
                html += "<li>\(inline(item))</li>"
                continue
            }

            // Cytat
            if trimmed.hasPrefix(">") {
                closeList()
                let q = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                html += "<blockquote>\(inline(q))</blockquote>"
                continue
            }

            // Zwykły akapit
            closeList()
            html += "<p>\(inline(trimmed))</p>"
        }
        if inCodeBlock { html += "</code></pre>" }
        closeList()
        html += "</body></html>"
        return html
    }

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1; idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]))
    }

    private static func unorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        // wzór: cyfry + ". "
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber { digits.append(line[idx]); idx = line.index(after: idx) }
        guard !digits.isEmpty, idx < line.endIndex, line[idx] == "." else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    /// Formatowanie liniowe: `code`, [text](url), **bold**, *italic*.
    /// Code-spany wycinamy najpierw (ich zawartość nie jest dalej parsowana ani emfazowana).
    private static func inline(_ text: String) -> String {
        let ns = text as NSString

        // 1. Wytnij code-spany do placeholderów.
        var codeSpans: [String] = []
        var assembled = ""
        var lastEnd = 0
        if let codeRegex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            for m in codeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                assembled += escape(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
                let content = ns.substring(with: m.range(at: 1))
                assembled += "\u{0001}\(codeSpans.count)\u{0001}"
                codeSpans.append("<code>\(escape(content))</code>")
                lastEnd = m.range.location + m.range.length
            }
        }
        assembled += escape(ns.substring(from: lastEnd))

        // 2. Linki.
        assembled = regexReplace(assembled, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")

        // 3. Emfaza. Wymagamy treści bez spacji na brzegach (CommonMark-ish), więc
        //    "3 * 4", "snake_case" czy samotny marker nie tworzą tagów.
        assembled = regexReplace(assembled, "\\*\\*(\\S(?:.*?\\S)?)\\*\\*", "<strong>$1</strong>")
        assembled = regexReplace(assembled, "(?<![A-Za-z0-9_])__(\\S(?:.*?\\S)?)__(?![A-Za-z0-9_])", "<strong>$1</strong>")
        assembled = regexReplace(assembled, "\\*(\\S(?:.*?\\S)?)\\*", "<em>$1</em>")
        assembled = regexReplace(assembled, "(?<![A-Za-z0-9_])_(\\S(?:.*?\\S)?)_(?![A-Za-z0-9_])", "<em>$1</em>")

        // 4. Przywróć code-spany.
        for (i, span) in codeSpans.enumerated() {
            assembled = assembled.replacingOccurrences(of: "\u{0001}\(i)\u{0001}", with: span)
        }
        return assembled
    }

    private static func regexReplace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - NSAttributedString → Markdown (do zapisu)

    static func fromAttributed(_ attr: NSAttributedString) -> String {
        let full = attr.string as NSString
        var out: [String] = []

        attr.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attr.length)) { _, _, _ in }

        // Iteruj po akapitach (rozdzielone \n).
        var paragraphStart = 0
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byParagraphs) { sub, subRange, _, _ in
            _ = paragraphStart
            paragraphStart = subRange.location
            let paragraphAttr = attr.attributedSubstring(from: subRange)
            let line = renderParagraph(paragraphAttr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { out.append(line) }
        }
        let joined = out.joined(separator: "\n\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    private static func renderParagraph(_ attr: NSAttributedString) -> String {
        var result = ""
        let range = NSRange(location: 0, length: attr.length)
        attr.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            var chunk = (attr.string as NSString).substring(with: subRange)
            chunk = chunk.replacingOccurrences(of: "\n", with: " ")
            if chunk.trimmingCharacters(in: .whitespaces).isEmpty { result += chunk; return }
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { chunk = "**\(chunk)**" }
                if traits.contains(.italic) { chunk = "*\(chunk)*" }
            }
            result += chunk
        }
        return result
    }
}
