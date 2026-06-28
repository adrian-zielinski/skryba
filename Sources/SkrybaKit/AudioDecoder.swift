import Foundation
import AVFoundation

/// Dekoduje dowolny plik audio/wideo do próbek wymaganych przez whisper:
/// 16 kHz, mono, Float32 znormalizowane do [-1, 1].
///
/// Najpierw próbuje AVFoundation (wbudowane w macOS — obsługuje m4a, mp3, wav,
/// aac, aiff, mov, mp4, m4v i inne). Dla formatów, których AVFoundation nie zna
/// (ogg/opus, flac, webm, mkv), używa `ffmpeg`, jeśli jest dostępny w systemie.
public enum AudioDecoder {

    public static let targetSampleRate: Double = 16_000

    /// Zwraca próbki 16 kHz mono Float32.
    public static func decode(url: URL) async throws -> [Float] {
        do {
            return try await decodeWithAVFoundation(url: url)
        } catch {
            // Fallback: ffmpeg (jeśli jest w systemie).
            if let ffmpeg = FFmpegDecoder.locate() {
                return try FFmpegDecoder.decode(url: url, ffmpeg: ffmpeg)
            }
            // Brak ffmpeg — zachowaj pierwotną przyczynę, jeśli ją znamy.
            if error is SkrybaError { throw error }
            throw SkrybaError.unsupportedAudio(url.lastPathComponent)
        }
    }

    static func decodeWithAVFoundation(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SkrybaError.noAudioTrack(url.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SkrybaError.decodeFailed(url.lastPathComponent)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SkrybaError.decodeFailed(url.lastPathComponent)
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                if count > 0 {
                    var chunk = [Float](repeating: 0, count: count)
                    chunk.withUnsafeMutableBytes { raw in
                        _ = CMBlockBufferCopyDataBytes(
                            block, atOffset: 0, dataLength: length,
                            destination: raw.baseAddress!)
                    }
                    samples.append(contentsOf: chunk)
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw reader.error ?? SkrybaError.decodeFailed(url.lastPathComponent)
        }
        // Pusty wynik traktuj jako porażkę dekodowania — pozwala spróbować ffmpeg.
        guard !samples.isEmpty else {
            throw SkrybaError.decodeFailed(url.lastPathComponent)
        }
        return samples
    }
}

/// Dekoder zapasowy oparty o zewnętrzny `ffmpeg` (opcjonalny).
enum FFmpegDecoder {

    static func locate() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Spróbuj odnaleźć w PATH.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func decode(url: URL, ffmpeg: String) throws -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin", "-loglevel", "quiet",
            "-i", url.path,
            "-ar", "16000", "-ac", "1",
            "-f", "f32le", "-",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Opróżniaj stderr równolegle, by pełny bufor potoku nie zablokował ffmpeg.
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global().async { _ = errHandle.readDataToEndOfFile() }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SkrybaError.decodeFailed(url.lastPathComponent)
        }
        // f32le: długość musi być wielokrotnością rozmiaru Float; kopiujemy bezpiecznie.
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else {
            throw SkrybaError.decodeFailed(url.lastPathComponent)
        }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }
}
