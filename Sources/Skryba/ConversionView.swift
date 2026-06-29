import SwiftUI
import SkrybaKit

struct ConversionView: View {
    @EnvironmentObject var model: ConversionModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if model.jobs.isEmpty { dropZone } else { jobList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Format docelowy")
                .foregroundStyle(.secondary)
            Picker("", selection: $model.targetFormat) {
                ForEach(model.availableTargets) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .disabled(model.availableTargets.isEmpty)
            .help("Na jaki format przekonwertować wrzucone pliki")

            Spacer()

            Button { model.chooseInputFiles() } label: {
                Label("Dodaj pliki", systemImage: "plus")
            }
            .disabled(model.isProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Przeciągnij dokument do konwersji")
                .font(.title3)
            Text("PDF, Word, Markdown, RTF, HTML, ODT, PowerPoint, Excel, Keynote, Numbers, Pages.\nApka wykryje format i zapyta, na co przekonwertować.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

    private var jobList: some View {
        List {
            ForEach(model.jobs) { job in
                ConvJobRow(job: job)
                    .contextMenu {
                        if let out = job.outputURL {
                            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        }
                        Button("Usuń z listy") { model.removeJob(job.id) }
                            .disabled(job.status == .converting)
                    }
            }
        }
        .listStyle(.inset)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isProcessing { ProgressView().controlSize(.small) }
            Text(model.statusMessage)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button { model.chooseOutputDirectory() } label: {
                Label(model.outputDirectory.lastPathComponent, systemImage: "folder").font(.callout)
            }
            .buttonStyle(.plain)
            .help("Folder docelowy: \(model.outputDirectory.path)")

            if !model.jobs.isEmpty && !model.isProcessing {
                Button("Wyczyść") { model.clearFinished() }
            }
            if model.isProcessing {
                Button("Przerwij", role: .destructive) { model.cancel() }
            } else {
                Button { model.start() } label: {
                    Label("Konwertuj", systemImage: "arrow.right.doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.jobs.isEmpty || model.availableTargets.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ConvJobRow: View {
    let job: ConversionModel.Job

    var body: some View {
        HStack(spacing: 12) {
            statusIcon.frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.fileName).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(job.status == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer()
            if let fmt = job.format {
                Text(fmt.fileExtension.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .converting: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch job.status {
        case .waiting: return job.format?.displayName ?? "Nieobsługiwany format"
        case .converting: return "Konwertuję…"
        case .done: return job.outputURL.map { "Zapisano: \($0.lastPathComponent)" } ?? "Gotowe"
        case .failed: return job.error ?? "Błąd"
        case .skipped: return job.error ?? "Pominięto"
        }
    }
}
