import Foundation

/// Formaty dokumentów obsługiwane przez moduł konwersji.
public enum DocumentFormat: String, CaseIterable, Sendable, Identifiable {
    case md, txt, rtf, html, docx, odt, pdf      // dokumenty tekstowe
    case pptx, xlsx                              // Office: prezentacja / arkusz
    case key, numbers, pages                     // Apple iWork (wymaga apki)

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .md: return "Markdown (.md)"
        case .txt: return "Tekst (.txt)"
        case .rtf: return "RTF (.rtf)"
        case .html: return "HTML (.html)"
        case .docx: return "Word (.docx)"
        case .odt: return "OpenDocument (.odt)"
        case .pdf: return "PDF (.pdf)"
        case .pptx: return "PowerPoint (.pptx)"
        case .xlsx: return "Excel (.xlsx)"
        case .key: return "Keynote (.key)"
        case .numbers: return "Numbers (.numbers)"
        case .pages: return "Pages (.pages)"
        }
    }

    public enum Category: Sendable { case text, presentation, spreadsheet, iwork }

    public var category: Category {
        switch self {
        case .md, .txt, .rtf, .html, .docx, .odt, .pdf: return .text
        case .pptx: return .presentation
        case .xlsx: return .spreadsheet
        case .key, .numbers, .pages: return .iwork
        }
    }

    /// Czy potrafimy odczytać ten format natywnie (bez aplikacji Apple).
    public var nativeReadable: Bool {
        switch self {
        case .md, .txt, .rtf, .html, .docx, .odt, .pdf, .pptx, .xlsx: return true
        case .key, .numbers, .pages: return false
        }
    }

    /// Czy potrafimy zapisać ten format natywnie.
    /// PPTX/XLSX i iWork obsługujemy tylko jako ŹRÓDŁA (odczyt) — zapis do
    /// prezentacji/arkusza jest semantycznie problematyczny i nietestowalny z tła.
    public var nativeWritable: Bool {
        switch self {
        case .md, .txt, .rtf, .html, .docx, .odt, .pdf: return true
        case .pptx, .xlsx, .key, .numbers, .pages: return false
        }
    }

    /// Format wymaga zainstalowanej apki Apple, by go ODCZYTAĆ (iWork).
    public var requiresAppToRead: Bool { category == .iwork }

    /// Format wymaga zainstalowanej aplikacji Apple (eksport przez automatyzację).
    public var requiresAppleApp: Bool { category == .iwork }

    /// Nazwa aplikacji Apple obsługującej ten format (dla iWork).
    public var appleAppName: String? {
        switch self {
        case .key: return "Keynote"
        case .numbers: return "Numbers"
        case .pages: return "Pages"
        default: return nil
        }
    }

    /// Wszystkie rozpoznawane rozszerzenia → format.
    public static func detect(_ url: URL) -> DocumentFormat? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown": return .md
        case "txt", "text": return .txt
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "docx": return .docx
        case "odt": return .odt
        case "pdf": return .pdf
        case "pptx": return .pptx
        case "xlsx": return .xlsx
        case "key": return .key
        case "numbers": return .numbers
        case "pages": return .pages
        default: return nil
        }
    }

    /// Dostępne formaty docelowe dla danego źródła (bez samego źródła).
    /// Po odczycie wszystko sprowadzamy do tekstu, więc cele to formaty zapisywalne.
    public static func targets(for source: DocumentFormat, includeAppleApps: Bool) -> [DocumentFormat] {
        allCases.filter { target in
            guard target != source else { return false }
            if target.requiresAppleApp { return includeAppleApps }
            return target.nativeWritable
        }
    }
}
