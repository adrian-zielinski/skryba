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
        /// Plik pobrany z linku do folderu tymczasowego — usuwamy po transkrypcji.
        var isTemporary = false
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

    // Pobieranie z linku (YouTube/X/Instagram…).
    @Published var linkURL = ""
    @Published var linkBusy = false
    @Published var probedInfo: MediaInfo?       // ustawione → pokaż arkusz wyboru rozdzielczości
    private var probedURL = ""

    let store = ModelStore.shared
    private var queueTask: Task<Void, Never>?
    private var cancelFlag: CancellationFlag?

    /// Wywoływane przez „Konwertuj na…" przy ukończonej transkrypcji
    /// (ustawiane przez RootView: dodaje plik do zakładki konwersji i przełącza ją).
    var onConvertRequest: ((URL) -> Void)?

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

    // MARK: - Link (YouTube/X/Instagram…)

    var linkValid: Bool { MediaDownloader.isLikelyMediaURL(linkURL) }

    private func ensureDownloader() async throws {
        if MediaDownloader.shared.locateYTDLP() == nil {
            statusMessage = "Pobieram narzędzie do pobierania (jednorazowo)…"
            _ = try await MediaDownloader.shared.ensureYTDLP { p in
                Task { @MainActor in self.modelDownloadProgress = p }
            }
        }
    }

    /// Wklej link → pobierz tylko dźwięk do folderu tymczasowego → transkrybuj → usuń plik.
    func transcribeFromLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MediaDownloader.isLikelyMediaURL(url), !linkBusy, !isProcessing else { return }
        linkBusy = true
        Task {
            do {
                try await ensureDownloader()
                statusMessage = "Pobieram dźwięk z linku…"
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("skryba-link-\(UUID().uuidString)", isDirectory: true)
                let audio = try await MediaDownloader.shared.downloadAudio(url: url, to: temp) { p in
                    Task { @MainActor in
                        self.modelDownloadProgress = p
                        self.statusMessage = "Pobieram dźwięk z linku… \(Int(p * 100))%"
                    }
                }
                jobs.append(Job(url: audio, isTemporary: true))
                linkURL = ""
                linkBusy = false
                start()
            } catch {
                statusMessage = "Błąd linku: \(error.localizedDescription)"
                linkBusy = false
            }
        }
    }

    /// Sprawdź link → pokaż dostępne rozdzielczości i opcję „tylko dźwięk".
    func probeLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MediaDownloader.isLikelyMediaURL(url), !linkBusy else { return }
        linkBusy = true
        Task {
            do {
                try await ensureDownloader()
                statusMessage = "Sprawdzam link…"
                let info = try await MediaDownloader.shared.probe(url: url)
                probedURL = url
                probedInfo = info
                statusMessage = info.title
            } catch {
                statusMessage = "Błąd linku: \(error.localizedDescription)"
            }
            linkBusy = false
        }
    }

    /// Pobierz wybraną rozdzielczość (lub sam dźwięk) na dysk (do Pobranych).
    func downloadFromLink(height: Int?, audioOnly: Bool) {
        let url = probedURL
        probedInfo = nil
        guard !url.isEmpty, !linkBusy else { return }
        linkBusy = true
        Task {
            do {
                let downloads = FileManager.default
                    .urls(for: .downloadsDirectory, in: .userDomainMask).first!
                statusMessage = "Pobieram…"
                let file = try await MediaDownloader.shared.download(
                    url: url, height: height, audioOnly: audioOnly, to: downloads) { p in
                    Task { @MainActor in
                        self.modelDownloadProgress = p
                        self.statusMessage = "Pobieram… \(Int(p * 100))%"
                    }
                }
                statusMessage = "Pobrano: \(file.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                statusMessage = "Błąd pobierania: \(error.localizedDescription)"
            }
            linkBusy = false
        }
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
            let isTemp = jobs[idx].isTemporary
            // Plik pobrany z linku usuwamy po przetworzeniu (także przy przerwaniu).
            defer { if isTemp { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
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
