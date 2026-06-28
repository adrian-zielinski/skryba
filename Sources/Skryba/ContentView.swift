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
                JobRow(job: job)
                    .contextMenu {
                        if let out = job.outputURL {
                            Button("Pokaż w Finderze") {
                                NSWorkspace.shared.activateFileViewerSelecting([out])
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

// MARK: - Wiersz kolejki

struct JobRow: View {
    let job: AppModel.Job

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
