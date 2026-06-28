import Foundation
import SwiftUI
import AppKit
import SkrybaKit

@MainActor
final class AppModel: ObservableObject {

    enum JobStatus: Equatable {
        case waiting, decoding, transcribing, done, failed
    }

    struct Job: Identifiable {
        let id = UUID()
        let url: URL
        var status: JobStatus = .waiting
        var progress: Double = 0
        var outputURL: URL?
        var error: String?
        var fileName: String { url.lastPathComponent }
    }

    // Ustawienia (utrwalane w UserDefaults).
    @Published var outputDirectory: URL
    @Published var selectedModelID: String
    @Published var language: String
    @Published var format: OutputFormat

    // Stan kolejki.
    @Published var jobs: [Job] = []
    @Published var isProcessing = false
    @Published var statusMessage = "Gotowy do pracy"

    // Modele.
    @Published var installedModelIDs: Set<String> = []
    @Published var downloadingModelID: String?
    @Published var modelDownloadProgress: Double = 0

    let store = ModelStore.shared
    private var queueTask: Task<Void, Never>?
    private var cancelFlag: CancellationFlag?

    static let languages: [(code: String, name: String)] = [
        ("auto", "Wykryj automatycznie"),
        ("pl", "Polski"),
        ("en", "Angielski"),
        ("de", "Niemiecki"),
        ("uk", "Ukraiński"),
        ("ru", "Rosyjski"),
        ("es", "Hiszpański"),
        ("fr", "Francuski"),
        ("it", "Włoski"),
    ]

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "outputDirectory") {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Transkrypcje", isDirectory: true)
        }
        selectedModelID = defaults.string(forKey: "selectedModelID") ?? ModelCatalog.defaultModelID
        language = defaults.string(forKey: "language") ?? "auto"
        format = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "markdown") ?? .markdown
        refreshInstalled()
    }

    var selectedModel: WhisperModel {
        ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.defaultModel
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(outputDirectory.path, forKey: "outputDirectory")
        d.set(selectedModelID, forKey: "selectedModelID")
        d.set(language, forKey: "language")
        d.set(format.rawValue, forKey: "format")
    }

    func refreshInstalled() {
        installedModelIDs = Set(store.installedModels().map { $0.id })
    }

    // MARK: - Pliki

    func addFiles(_ urls: [URL]) {
        let expanded = SupportedMedia.expand(urls)
        let existing = Set(jobs.map { $0.url.standardizedFileURL })
        for url in expanded where !existing.contains(url.standardizedFileURL) {
            jobs.append(Job(url: url))
        }
        if statusMessage == "Gotowy do pracy" && !jobs.isEmpty {
            statusMessage = "\(jobs.count) plik(ów) w kolejce"
        }
    }

    func removeJob(_ id: UUID) {
        if let job = jobs.first(where: { $0.id == id }),
           job.status == .decoding || job.status == .transcribing { return }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done || $0.status == .failed }
    }

    func clearAll() {
        guard !isProcessing else { return }
        jobs.removeAll()
        statusMessage = "Gotowy do pracy"
    }

    // MARK: - Modele

    func downloadModel(_ model: WhisperModel) {
        guard downloadingModelID == nil else { return }
        downloadingModelID = model.id
        modelDownloadProgress = 0
        Task {
            do {
                _ = try await store.download(model) { p in
                    Task { @MainActor in self.modelDownloadProgress = p }
                }
                statusMessage = "Pobrano model \(model.displayName)"
            } catch {
                statusMessage = "Błąd pobierania: \(error.localizedDescription)"
            }
            downloadingModelID = nil
            refreshInstalled()
        }
    }

    func deleteModel(_ model: WhisperModel) {
        try? store.delete(model)
        refreshInstalled()
    }

    // MARK: - Uruchomienie

    func start() {
        guard !isProcessing, !jobs.isEmpty, downloadingModelID == nil else { return }
        persist()
        let flag = CancellationFlag()
        cancelFlag = flag
        isProcessing = true
        queueTask = Task { await runQueue(cancelFlag: flag) }
    }

    func cancel() {
        cancelFlag?.cancel()
        queueTask?.cancel()
    }

    private func runQueue(cancelFlag: CancellationFlag) async {
        let model = selectedModel

        // 1) Upewnij się, że model jest na dysku.
        let modelPath: String
        if store.isInstalled(model) {
            modelPath = store.localURL(for: model).path
        } else {
            statusMessage = "Pobieram model \(model.displayName) (~\(model.approxSizeMB) MB)..."
            downloadingModelID = model.id
            do {
                let url = try await store.download(model) { p in
                    Task { @MainActor in self.modelDownloadProgress = p }
                }
                modelPath = url.path
            } catch {
                statusMessage = "Nie udało się pobrać modelu: \(error.localizedDescription)"
                downloadingModelID = nil
                isProcessing = false
                return
            }
            downloadingModelID = nil
            refreshInstalled()
        }

        // 2) Wczytaj model (poza głównym wątkiem).
        let lang = language
        let fmt = format
        let outDir = outputDirectory
        statusMessage = "Wczytuję model..."
        let transcriber: Transcriber
        do {
            transcriber = try await Task.detached {
                try Transcriber(modelPath: modelPath, language: lang)
            }.value
        } catch {
            statusMessage = "Błąd modelu: \(error.localizedDescription)"
            isProcessing = false
            return
        }

        // 3) Przetwarzaj po kolei.
        let ids = jobs.filter { $0.status != .done }.map(\.id)
        var completed = 0
        for jid in ids {
            if cancelFlag.isCancelled { break }
            guard let idx = jobs.firstIndex(where: { $0.id == jid }) else { continue }
            let url = jobs[idx].url
            update(jid) { $0.status = .decoding; $0.progress = 0; $0.error = nil }
            statusMessage = "Przetwarzam: \(url.lastPathComponent)"
            do {
                let result = try await Task.detached {
                    try await transcriber.transcribe(
                        url: url, outputDirectory: outDir, format: fmt,
                        onDecodeStarted: {
                            Task { @MainActor in self.update(jid) { $0.status = .transcribing } }
                        },
                        onProgress: { p in
                            Task { @MainActor in self.update(jid) { $0.status = .transcribing; $0.progress = p } }
                        },
                        shouldCancel: { cancelFlag.isCancelled })
                }.value
                update(jid) { $0.status = .done; $0.progress = 1; $0.outputURL = result.outputURL }
                completed += 1
            } catch SkrybaError.cancelled {
                update(jid) { $0.status = .waiting; $0.progress = 0 }
                break
            } catch {
                update(jid) { $0.status = .failed; $0.error = error.localizedDescription }
            }
        }

        isProcessing = false
        statusMessage = cancelFlag.isCancelled
            ? "Przerwano (gotowe: \(completed))"
            : "Gotowe: \(completed)/\(ids.count)"
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            change(&jobs[i])
        }
    }

    // MARK: - Panele wyboru

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder na pliki transkrypcji"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            persist()
        }
    }

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Dodaj"
        panel.message = "Wybierz pliki audio/wideo lub foldery"
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }
}

/// Wątkowo-bezpieczna flaga anulowania. Ustawiana z głównego wątku (cancel()),
/// czytana z wątku obliczeń whisper przez abort_callback.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}
