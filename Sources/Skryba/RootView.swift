import SwiftUI

struct RootView: View {
    @StateObject private var transcription = AppModel()
    @StateObject private var conversion = ConversionModel()
    @StateObject private var pdfEditor = PDFEditorModel()
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .environmentObject(transcription)
                .tabItem { Label("Transkrypcja", systemImage: "waveform") }
                .tag(0)
            ConversionView()
                .environmentObject(conversion)
                .tabItem { Label("Konwersja", systemImage: "arrow.left.arrow.right") }
                .tag(1)
            PDFEditorView()
                .environmentObject(pdfEditor)
                .tabItem { Label("Edytor PDF", systemImage: "pencil.and.outline") }
                .tag(2)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            // „Konwertuj na…" z ukończonej transkrypcji: dodaj plik do konwersji i przełącz zakładkę.
            transcription.onConvertRequest = { url in
                conversion.addFiles([url])
                selection = 1
            }
        }
    }
}
