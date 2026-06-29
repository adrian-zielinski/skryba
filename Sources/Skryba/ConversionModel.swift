import Foundation
import SwiftUI
import AppKit
import SkrybaKit

@MainActor
final class ConversionModel: ObservableObject {

    enum JobStatus: Equatable { case waiting, converting, done, failed, skipped }

    struct Job: Identifiable {
        let id = UUID()
        let url: URL
        let format: DocumentFormat?
        var status: JobStatus = .waiting
        var outputURL: URL?
        var error: String?
        var fileName: String { url.lastPathComponent }
    }

    @Published var jobs: [Job] = []
    @Published var targetFormat: DocumentFormat = .md
    @Published var outputDirectory: URL
    @Published var isProcessing = false
    @Published var statusMessage = "Przeciągnij dokument do konwersji"

    private var queueTask: Task<Void, Never>?
    private var cancelFlag: CancellationFlag?

    init() {
        if let path = UserDefaults.standard.string(forKey: "conversionOutputDirectory") {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Konwersje", isDirectory: true)
        }
    }

    func persist() {
        UserDefaults.standard.set(outputDirectory.path, forKey: "conversionOutputDirectory")
    }

    /// Formaty docelowe wspólne dla wszystkich wrzuconych plików.
    var availableTargets: [DocumentFormat] {
        let sources = Set(jobs.compactMap { $0.format })
        guard !sources.isEmpty else { return [] }
        var common: Set<DocumentFormat>?
        for source in sources {
            let targets = Set(DocumentFormat.targets(for: source, includeAppleApps: false))
            common = common.map { $0.intersection(targets) } ?? targets
        }
        let allowed = common ?? []
        return DocumentFormat.allCases.filter { allowed.contains($0) }
    }

    var hasUnsupportedFiles: Bool {
        jobs.contains { $0.format == nil }
    }

    // MARK: - Pliki

    func addFiles(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.url.standardizedFileURL })
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard !existing.contains(url.standardizedFileURL) else { continue }
            jobs.append(Job(url: url, format: DocumentFormat.detect(url)))
        }
        ensureValidTarget()
        updatePrompt()
    }

    func removeJob(_ id: UUID) {
        if let job = jobs.first(where: { $0.id == id }), job.status == .converting { return }
        jobs.removeAll { $0.id == id }
        ensureValidTarget()
        updatePrompt()
    }

    func clearFinished() { jobs.removeAll { $0.status == .done || $0.status == .failed || $0.status == .skipped } }

    func clearAll() {
        guard !isProcessing else { return }
        jobs.removeAll()
        statusMessage = "Przeciągnij dokument do konwersji"
    }

    private func ensureValidTarget() {
        let targets = availableTargets
        guard !targets.isEmpty else { return }
        if !targets.contains(targetFormat) {
            // Preferuj Markdown („mielić do .md"), inaczej pierwszy dostępny.
            targetFormat = targets.contains(.md) ? .md : targets[0]
        }
    }

    private func updatePrompt() {
        if jobs.isEmpty {
            statusMessage = "Przeciągnij dokument do konwersji"
        } else if hasUnsupportedFiles {
            statusMessage = "Część plików ma nieobsługiwany format i zostanie pominięta"
        } else {
            let types = Set(jobs.compactMap { $0.format?.displayName })
            statusMessage = "Wykryto: \(types.sorted().joined(separator: ", ")). Wybierz format docelowy i kliknij Konwertuj."
        }
    }

    // MARK: - Uruchomienie

    func start() {
        guard !isProcessing, !jobs.isEmpty else { return }
        persist()
        let target = targetFormat
        let outDir = outputDirectory
        let flag = CancellationFlag()
        cancelFlag = flag
        isProcessing = true
        queueTask = Task { await runQueue(target: target, outDir: outDir, cancelFlag: flag) }
    }

    func cancel() {
        cancelFlag?.cancel()
        queueTask?.cancel()
    }

    private func runQueue(target: DocumentFormat, outDir: URL, cancelFlag: CancellationFlag) async {
        let ids = jobs.filter { $0.status != .done }.map(\.id)
        var done = 0
        for jid in ids {
            if cancelFlag.isCancelled { break }
            guard let idx = jobs.firstIndex(where: { $0.id == jid }) else { continue }
            let job = jobs[idx]
            guard let source = job.format else {
                update(jid) { $0.status = .skipped; $0.error = "nieobsługiwany format" }
                continue
            }
            if source == target {
                update(jid) { $0.status = .skipped; $0.error = "źródło i cel są takie same" }
                continue
            }
            let url = job.url
            update(jid) { $0.status = .converting; $0.error = nil }
            statusMessage = "Konwertuję: \(url.lastPathComponent) → \(target.fileExtension)"
            do {
                // convert() jest nieizolowane i async: ciężka praca biegnie poza main,
                // a fragmenty AppKit (HTML/DOCX/ODT/RTF) same skaczą na MainActor.
                let result = try await DocumentConverter.convert(
                    input: url, to: target, outputDirectory: outDir,
                    shouldCancel: { cancelFlag.isCancelled })
                update(jid) { $0.status = .done; $0.outputURL = result }
                done += 1
            } catch SkrybaError.cancelled {
                update(jid) { $0.status = .waiting }
                break
            } catch {
                update(jid) { $0.status = .failed; $0.error = error.localizedDescription }
            }
        }
        isProcessing = false
        statusMessage = cancelFlag.isCancelled ? "Przerwano (gotowe: \(done))" : "Gotowe: \(done)/\(ids.count)"
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    // MARK: - Panele

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder na przekonwertowane pliki"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            persist()
        }
    }

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Dodaj"
        panel.message = "Wybierz dokumenty do konwersji"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
}
