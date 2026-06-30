import SwiftUI
import AppKit
import PDFKit
import SkrybaKit

struct PDFEditorView: View {
    @EnvironmentObject var model: PDFEditorModel
    @State private var showSignatureCreator = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.document == nil {
                dropZone
            } else {
                HStack(spacing: 0) {
                    PageThumbnailList().environmentObject(model)
                        .frame(width: 150)
                    Divider()
                    PDFCanvas(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    SidePanel(showSignatureCreator: $showSignatureCreator).environmentObject(model)
                        .frame(width: 230)
                }
            }
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                model.open(pdf); return true
            }
            return false
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $showSignatureCreator) {
            SignatureCreatorSheet().environmentObject(model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.openPanel() } label: { Label("Otwórz PDF", systemImage: "doc") }

            if model.document != nil {
                Divider().frame(height: 18)
                Picker("", selection: $model.tool) {
                    ForEach(PDFEditorModel.Tool.allCases) { tool in
                        Label(tool.label, systemImage: tool.systemImage).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
                .labelsHidden()

                if model.tool == .draw || model.tool == .text {
                    ColorPicker("", selection: $model.inkColor).labelsHidden()
                }
                if model.tool == .draw {
                    Slider(value: $model.inkWidth, in: 1...8).frame(width: 80)
                }
            }
            Spacer()
            if model.document != nil {
                Button { model.save() } label: { Label("Zapisz", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                Button("Eksportuj…") { model.exportAs() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Przeciągnij PDF, aby go edytować")
                .font(.title3)
            Text("Dodawaj tekst, rysuj, wstawiaj podpisy, usuwaj i wstawiaj strony.")
                .font(.callout).foregroundStyle(.secondary)
            Button { model.openPanel() } label: { Label("Otwórz PDF", systemImage: "doc") }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusMessage).font(.callout).lineLimit(1).truncationMode(.middle)
            if model.isDirty { Text("• niezapisane").font(.callout).foregroundStyle(.orange) }
            Spacer()
            if model.document != nil {
                Text(toolHint).font(.caption).foregroundStyle(.secondary)
                Text("\(model.pageCount) stron").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var toolHint: String {
        switch model.tool {
        case .select: return "Kliknij nakładkę, by przesunąć • Delete usuwa"
        case .text: return "Kliknij, by dodać tekst"
        case .draw: return "Rysuj przeciągając"
        case .whiteout: return "Przeciągnij, by zamalować"
        case .signature: return model.signatures.isEmpty ? "Dodaj podpis w panelu po prawej" : "Kliknij, by wstawić podpis"
        }
    }
}

// MARK: - Miniatury stron

struct PageThumbnailList: View {
    @EnvironmentObject var model: PDFEditorModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(thumbnails(), id: \.index) { item in
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: item.image)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .border(Color.secondary.opacity(0.3))
                                .onTapGesture { model.goTo(item.index) }
                            Button {
                                model.deletePage(item.index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .background(Circle().fill(.white))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .help("Usuń stronę \(item.index + 1)")
                        }
                        Text("\(item.index + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        if let url = urls.first { model.insertFile(url, at: item.index + 1); return true }
                        return false
                    }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private struct Thumb { let index: Int; let image: NSImage }

    private func thumbnails() -> [Thumb] {
        _ = model.revision // przelicz po zmianach
        guard let doc = model.document else { return [] }
        var result: [Thumb] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                result.append(Thumb(index: i, image: page.thumbnail(of: NSSize(width: 120, height: 160), for: .mediaBox)))
            }
        }
        return result
    }
}

// MARK: - Panel boczny: źródła + podpisy

struct SidePanel: View {
    @EnvironmentObject var model: PDFEditorModel
    @Binding var showSignatureCreator: Bool
    @State private var sourcesTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Źródła
            Text("Źródła dokumentów").font(.headline).padding(10)
            Text("Przeciągnij tu PDF-y/obrazy, a stamtąd na miniaturę strony, by wstawić.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sourceFiles, id: \.self) { url in
                        HStack {
                            Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.fill" : "photo")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.callout)
                            Spacer()
                            Button { model.removeSource(url) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .draggable(url)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(sourcesTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .dropDestination(for: URL.self) { urls, _ in model.addSourceFiles(urls); return true } isTargeted: { sourcesTargeted = $0 }

            Divider()

            // Podpisy
            HStack {
                Text("Podpisy").font(.headline)
                Spacer()
                Button { showSignatureCreator = true } label: { Image(systemName: "plus") }
                    .help("Dodaj podpis")
            }
            .padding(10)

            if model.tool == .signature {
                Text("Kliknij na dokumencie, by wstawić wybrany podpis.")
                    .font(.caption).foregroundStyle(Color.accentColor).padding(.horizontal, 10)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.signatures, id: \.self) { url in
                        if let img = model.store.image(url) {
                            Image(nsImage: img)
                                .resizable().scaledToFit()
                                .frame(height: 50)
                                .padding(4)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(model.selectedSignature == url ? Color.accentColor : Color.secondary.opacity(0.3),
                                            lineWidth: model.selectedSignature == url ? 2 : 1))
                                .onTapGesture {
                                    model.selectedSignature = url
                                    model.tool = .signature
                                }
                                .contextMenu {
                                    Button("Usuń", role: .destructive) { model.deleteSignature(url) }
                                }
                        }
                    }
                }
                .padding(8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tworzenie podpisu

struct SignatureCreatorSheet: View {
    @EnvironmentObject var model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    private let pad = DrawPad()

    var body: some View {
        VStack(spacing: 14) {
            Text("Nowy podpis").font(.title2.bold())
            Picker("", selection: $mode) {
                Text("Narysuj").tag(0)
                Text("Wgraj obraz").tag(1)
                Text("Zdjęcie z kartki").tag(2)
                Text("Ze schowka").tag(3)
            }
            .pickerStyle(.segmented)

            switch mode {
            case 0:
                pad.frame(width: 460, height: 170)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Wyczyść") { pad.clear() }
                    Spacer()
                    Button("Zapisz podpis") {
                        model.saveDrawnSignature(paths: pad.paths, size: pad.size)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case 1:
                VStack(spacing: 10) {
                    Text("Wgraj gotowy obraz podpisu (najlepiej z przezroczystym tłem).")
                        .foregroundStyle(.secondary)
                    Button("Wybierz obraz…") {
                        if let url = pickImage() { model.importSignatureImage(url); dismiss() }
                    }
                    .controlSize(.large)
                }
                .frame(width: 460, height: 170)
            case 2:
                VStack(spacing: 10) {
                    Text("Wgraj zdjęcie podpisu na białej kartce. Skryba wytnie tło i zostawi sam podpis.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Wybierz zdjęcie…") {
                        if let url = pickImage() { model.importSignaturePhoto(url); dismiss() }
                    }
                    .controlSize(.large)
                }
                .frame(width: 460, height: 170)
            default:
                VStack(spacing: 10) {
                    Text("Skopiuj podpis do schowka (np. zrzut ekranu Cmd-Shift-Ctrl-4 z podpisu w Podglądzie, Notatkach czy na stronie), a tutaj wklej. Białe tło zostanie wycięte.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Wklej ze schowka") {
                        if model.importSignatureFromClipboard() { dismiss() }
                    }
                    .controlSize(.large)
                }
                .frame(width: 460, height: 170)
            }

            HStack {
                Spacer()
                Button("Zamknij") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
