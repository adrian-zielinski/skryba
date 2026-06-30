import Foundation

/// Pojedynczy format dostępny do pobrania (z yt-dlp).
public struct MediaFormat: Identifiable, Sendable, Hashable {
    public let id: String          // format_id
    public let ext: String
    public let height: Int?        // nil = tylko dźwięk
    public let filesizeBytes: Int64?
    public let isAudioOnly: Bool
    public let note: String
}

/// Informacje o materiale spod linku.
public struct MediaInfo: Sendable {
    public let title: String
    public let durationSeconds: Double?
    public let videoHeights: [Int]   // unikalne, rosnąco
    public let hasAudio: Bool
}

/// Pobieranie i sprawdzanie wideo/audio spod linku (YouTube, X, Instagram…)
/// przez `yt-dlp`. Binarka pobierana jest na żądanie do katalogu aplikacji.
public final class MediaDownloader: @unchecked Sendable {

    public static let shared = MediaDownloader()
    public let binDirectory: URL

    private let releaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    public init(binDirectory: URL? = nil) {
        if let binDirectory {
            self.binDirectory = binDirectory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.binDirectory = appSupport.appendingPathComponent("Skryba/bin", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.binDirectory, withIntermediateDirectories: true)
    }

    /// Wygląda jak adres http(s).
    public static func isLikelyMediaURL(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s) else { return false }
        return (url.scheme == "http" || url.scheme == "https") && (url.host?.contains(".") ?? false)
    }

    // MARK: - yt-dlp

    public func locateYTDLP() -> String? {
        let local = binDirectory.appendingPathComponent("yt-dlp").path
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/yt-dlp"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Zwraca ścieżkę do yt-dlp; pobiera binarkę, jeśli jej nie ma.
    public func ensureYTDLP(progress: ((Double) -> Void)? = nil) async throws -> String {
        if let existing = locateYTDLP() { return existing }
        progress?(0)
        let (tmp, response) = try await URLSession.shared.download(from: releaseURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SkrybaError.downloadFailed("yt-dlp HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let dest = binDirectory.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // Apple Silicon: zdejmij kwarantannę i podpisz ad-hoc, by binarka mogła się uruchomić.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        run("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        progress?(1)
        guard FileManager.default.isExecutableFile(atPath: dest.path) else {
            throw SkrybaError.downloadFailed("yt-dlp nie jest wykonywalny po pobraniu")
        }
        return dest.path
    }

    /// Wymuś pobranie najnowszej wersji yt-dlp.
    public func updateYTDLP() async throws {
        let dest = binDirectory.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: dest)
        _ = try await ensureYTDLP()
    }

    // MARK: - Sprawdzanie i pobieranie

    public func probe(url: String) async throws -> MediaInfo {
        let yt = try await ensureYTDLP()
        let result = try runProcess(yt, ["-J", "--no-warnings", "--no-playlist"] + siteArgs() + [url], onLine: nil)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkrybaError.downloadFailed("nie udało się odczytać informacji o linku")
        }
        let title = (json["title"] as? String) ?? "wideo"
        let duration = json["duration"] as? Double
        let formats = (json["formats"] as? [[String: Any]]) ?? []
        var heights = Set<Int>()
        var hasAudio = false
        for f in formats {
            let vcodec = f["vcodec"] as? String ?? "none"
            let acodec = f["acodec"] as? String ?? "none"
            if acodec != "none" { hasAudio = true }
            if vcodec != "none", let h = f["height"] as? Int, h > 0 { heights.insert(h) }
        }
        return MediaInfo(title: title, durationSeconds: duration,
                         videoHeights: heights.sorted(), hasAudio: hasAudio)
    }

    /// Pobiera SAM dźwięk w najlżejszej, transkrybowalnej formie (m4a, jeśli jest ffmpeg).
    /// Zwraca URL pliku. Używane do „transkrybuj bez zapisu na dysk".
    @discardableResult
    public func downloadAudio(url: String, to directory: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let yt = try await ensureYTDLP()
        var args = ["--no-warnings", "--no-playlist", "--newline"] + siteArgs() +
                   ["-o", directory.appendingPathComponent("%(title).200B.%(ext)s").path]
        if let ffmpegDir = ffmpegDirectory() {
            args += ["--ffmpeg-location", ffmpegDir, "-x", "--audio-format", "m4a"]
        } else {
            args += ["-f", "ba[ext=m4a]/ba/worst"]
        }
        args.append(url)
        return try await runDownload(yt, args, in: directory, progress: progress)
    }

    /// Pobiera wideo w danej rozdzielczości (lub sam dźwięk) do `directory`.
    @discardableResult
    public func download(url: String, height: Int?, audioOnly: Bool, to directory: URL,
                         progress: ((Double) -> Void)? = nil) async throws -> URL {
        if audioOnly { return try await downloadAudio(url: url, to: directory, progress: progress) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let yt = try await ensureYTDLP()
        var args = ["--no-warnings", "--no-playlist", "--newline"] + siteArgs() +
                   ["-o", directory.appendingPathComponent("%(title).200B.%(ext)s").path]
        if let ffmpegDir = ffmpegDirectory() { args += ["--ffmpeg-location", ffmpegDir] }
        let h = height.map(String.init) ?? "99999"
        args += ["-f", "b[height<=\(h)][ext=mp4]/b[height<=\(h)]/bv[height<=\(h)]+ba/b"]
        args.append(url)
        return try await runDownload(yt, args, in: directory, progress: progress)
    }

    // MARK: - Uruchamianie yt-dlp

    private func runDownload(_ yt: String, _ args: [String], in directory: URL,
                             progress: ((Double) -> Void)?) async throws -> URL {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let result = try runProcess(yt, args) { line in
            // [download]  12.6% of ...
            if let r = line.range(of: #"(\d{1,3}\.\d)%"#, options: .regularExpression) {
                let pct = Double(line[r].dropLast()) ?? 0
                progress?(pct / 100)
            }
        }
        guard result.exitCode == 0 else {
            throw SkrybaError.downloadFailed(downloaderMessage(result.stderr))
        }
        // Najnowszy/utworzony plik medialny w katalogu = wynik.
        let after = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let newFiles = after.filter { !before.contains($0) && !$0.hasPrefix(".") }
        guard let name = newFiles.sorted().last ?? after.sorted().last else {
            throw SkrybaError.downloadFailed("nie powstał plik wynikowy")
        }
        progress?(1)
        return directory.appendingPathComponent(name)
    }

    private func downloaderMessage(_ stderr: String) -> String {
        let line = stderr.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init)
        return line?.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
            ?? "pobieranie nie powiodło się"
    }

    private func ffmpegDirectory() -> String? {
        FFmpegDecoder.locate().map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Środowisko JavaScript do rozwiązania wyzwania nsig YouTube (inaczej część
    /// strumieni zwraca HTTP 403). Szuka deno/node/bun.
    private func jsRuntime() -> (name: String, path: String)? {
        let candidates: [(String, [String])] = [
            ("deno", ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]),
            ("node", ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]),
            ("bun", ["/opt/homebrew/bin/bun", "/usr/local/bin/bun"]),
        ]
        for (name, paths) in candidates {
            for p in paths where FileManager.default.isExecutableFile(atPath: p) { return (name, p) }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for (name, _) in candidates {
                for dir in pathEnv.split(separator: ":") {
                    let c = "\(dir)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: c) { return (name, c) }
                }
            }
        }
        return nil
    }

    /// Argumenty łagodzące blokady YouTube. Z runtime JS używamy domyślnych klientów
    /// (dają lekkie audio-only). Bez JS — klient android/tv, który działa bez nsig.
    private func siteArgs() -> [String] {
        if let rt = jsRuntime() { return ["--js-runtimes", "\(rt.name):\(rt.path)"] }
        return ["--extractor-args", "youtube:player_client=android,tv"]
    }

    /// Uruchamia proces, drenując oba potoki; opcjonalnie woła `onLine` dla każdej linii.
    private func runProcess(_ launchPath: String, _ args: [String],
                            onLine: ((String) -> Void)?) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = LineBox(onLine: onLine)
        let errBox = LineBox(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { outBox.feed($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errBox.feed($0.availableData) }

        try process.run()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outBox.flush(); errBox.flush()
        return (outBox.text, errBox.text, process.terminationStatus)
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
}

/// Zbiera dane z potoku, składa pełne linie i przekazuje je callbackowi.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var full = Data()
    private let onLine: ((String) -> Void)?
    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        full.append(data)
        buffer.append(data)
        // yt-dlp z --newline używa \r i \n jako separatorów postępu.
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[..<idx]
            buffer.removeSubrange(...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                onLine?(line)
            }
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine?(line) }
        buffer.removeAll()
        lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: full, encoding: .utf8) ?? ""
    }
}
