import SwiftUI

struct RootView: View {
    @StateObject private var transcription = AppModel()
    @StateObject private var conversion = ConversionModel()
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
        }
        .frame(minWidth: 680, minHeight: 500)
        .onAppear {
            // „Konwertuj na…" z ukończonej transkrypcji: dodaj plik do konwersji i przełącz zakładkę.
            transcription.onConvertRequest = { url in
                conversion.addFiles([url])
                selection = 1
            }
        }
    }
}
