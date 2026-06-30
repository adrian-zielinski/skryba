import SwiftUI
import SkrybaKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showModels = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            linkBar
            Divider()
            ZStack {
                if model.jobs.isEmpty {
                    dropZone
                } else {
                    jobList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $showModels) {
            ModelManagerView().environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.probedInfo != nil }, set: { if !$0 { model.probedInfo = nil } })) {
            LinkProbeSheet().environmentObject(model)
        }
    }

    private var linkBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Wklej link do filmu (YouTube, X, Instagram…)", text: $model.linkURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.transcribeFromLink() }
                .disabled(model.linkBusy)
            if model.linkBusy { ProgressView().controlSize(.small) }
            Button("Sprawdź") { model.probeLink() }
                .disabled(model.linkBusy || !model.linkValid)
                .help("Pokaż dostępne rozdzielczości i pobierz na dysk")
            Button { model.transcribeFromLink() } label: {
                Label("Transkrybuj z linku", systemImage: "arrow.down.to.line")
            }
            .disabled(model.linkBusy || !model.linkValid || model.isProcessing)
            .help("Pobierz sam dźwięk tymczasowo i przetranskrybuj — bez zapisu filmu na dysk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func convertAction(for job: AppModel.Job) -> (() -> Void)? {
        guard job.status == .done, let out = job.outputURL else { return nil }
        return { model.onConvertRequest?(out) }
    }

    // MARK: - Pasek narzędzi

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { showModels = true } label: {
                Label(model.selectedModel.displayName, systemImage: "brain.head.profile")
            }
            .help("Wybierz lub pobierz model transkrypcji")

            Divider().frame(height: 18)

            Picker("", selection: $model.language) {
                ForEach(AppModel.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .help("Język nagrania")

            Picker("", selection: $model.format) {
                ForEach(OutputFormat.allCases) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Format pliku wynikowego")

            Spacer()

            Button { model.chooseInputFiles() } label: {
                Label("Dodaj pliki", systemImage: "plus")
            }
            .disabled(model.isProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Strefa upuszczania

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Przeciągnij tutaj pliki audio lub wideo")
                .font(.title3)
            Text("albo użyj „Dodaj pliki”. Przetworzą się po kolei do wybranego folderu.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { model.chooseInputFiles() } label: {
                Label("Dodaj pliki", systemImage: "plus")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
                .padding(16)
        )
    }

    // MARK: - Lista kolejki

    private var jobList: some View {
        List {
            ForEach(model.jobs) { job in
                JobRow(job: job, onConvert: convertAction(for: job))
                    .contextMenu {
                        if let out = job.outputURL {
                            Button("Pokaż w Finderze") {
                                NSWorkspace.shared.activateFileViewerSelecting([out])
                            }
                            if job.status == .done {
                                Button("Konwertuj na…") { model.onConvertRequest?(out) }
                            }
                        }
                        Button("Usuń z listy") { model.removeJob(job.id) }
                            .disabled(job.status == .decoding || job.status == .transcribing)
                    }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if isTargeted {
                Rectangle().fill(Color.accentColor.opacity(0.08))
                    .overlay(Text("Upuść, aby dodać").font(.headline))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Pasek statusu

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isProcessing {
                ProgressView().controlSize(.small)
            }
            Text(model.statusMessage)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                model.chooseOutputDirectory()
            } label: {
                Label(model.outputDirectory.lastPathComponent, systemImage: "folder")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .help("Folder docelowy: \(model.outputDirectory.path)")

            if !model.jobs.isEmpty && !model.isProcessing {
                Button("Wyczyść") { model.clearFinished() }
                    .help("Usuń ukończone z listy")
            }

            if model.isProcessing {
                Button("Przerwij", role: .destructive) { model.cancel() }
            } else {
                Button {
                    model.start()
                } label: {
                    Label("Transkrybuj", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.jobs.isEmpty || model.downloadingModelID != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Arkusz pobierania z linku

struct LinkProbeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pobierz z linku").font(.title2.bold())
            if let info = model.probedInfo {
                Text(info.title).font(.headline).lineLimit(2)
                if let d = info.durationSeconds {
                    Text("Czas: \(formatDuration(d))").foregroundStyle(.secondary).font(.callout)
                }
                Divider()
                Text("Co pobrać na dysk (do Pobranych):").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if info.hasAudio {
                            Button { model.downloadFromLink(height: nil, audioOnly: true) } label: {
                                Label("Tylko dźwięk (m4a, najlżejsze)", systemImage: "music.note")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(info.videoHeights.reversed(), id: \.self) { h in
                            Button { model.downloadFromLink(height: h, audioOnly: false) } label: {
                                Label("Wideo \(h)p", systemImage: "film")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if info.videoHeights.isEmpty && !info.hasAudio {
                            Text("Brak dostępnych formatów.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            HStack { Spacer(); Button("Zamknij") { dismiss() } }
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Wiersz kolejki

struct JobRow: View {
    let job: AppModel.Job
    var onConvert: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.status == .transcribing {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                } else if let error = job.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if job.status == .transcribing {
                Text("\(Int(job.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if job.status == .done, let onConvert {
                Button { onConvert() } label: {
                    Label("Konwertuj na…", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Wyślij ten plik do zakładki Konwersja")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .decoding:
            ProgressView().controlSize(.small)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch job.status {
        case .waiting: return "Oczekuje"
        case .decoding: return "Dekodowanie audio..."
        case .transcribing: return "Transkrypcja..."
        case .done: return job.outputURL.map { "Zapisano: \($0.lastPathComponent)" } ?? "Gotowe"
        case .failed: return "Błąd"
        }
    }
}
