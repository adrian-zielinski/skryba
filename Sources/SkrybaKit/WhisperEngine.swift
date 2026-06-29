import Foundation
import whisper

/// Pojedynczy fragment transkrypcji z zakresem czasu (sekundy).
public struct TranscriptSegment: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Pudełko przenoszące domknięcie postępu przez granicę C-callbacku.
private final class ProgressBox {
    let callback: (Double) -> Void
    init(_ callback: @escaping (Double) -> Void) { self.callback = callback }
}

/// Pudełko przenoszące zapytanie o anulowanie do C-callbacku whisper_full.
private final class AbortBox {
    let shouldCancel: () -> Bool
    init(_ shouldCancel: @escaping () -> Bool) { self.shouldCancel = shouldCancel }
}

/// Opakowanie silnika whisper.cpp. Ładuje model raz i pozwala transkrybować
/// wiele plików tym samym kontekstem (ładowanie modelu jest kosztowne).
///
/// Klasa nie jest `Sendable` — kontekst whisper trzymaj i wołaj z jednego
/// miejsca (np. dedykowanego Taska / aktora po stronie wołającego).
public final class WhisperEngine {

    private let ctx: OpaquePointer
    public let modelName: String

    /// Wycisza wewnętrzne logi biblioteki whisper.cpp/ggml (raz na proces).
    /// Błędy i tak zgłaszamy przez `SkrybaError`.
    private static let loggingSilenced: Bool = {
        whisper_log_set({ _, _, _ in }, nil)
        return true
    }()

    /// - Parameters:
    ///   - modelPath: ścieżka do pliku `ggml-*.bin`.
    ///   - useGPU: użyj akceleracji Metal, jeśli dostępna (domyślnie tak).
    public init(modelPath: String, useGPU: Bool = true) throws {
        _ = WhisperEngine.loggingSilenced
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw SkrybaError.modelNotFound(modelPath)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw SkrybaError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        self.modelName = (modelPath as NSString).lastPathComponent
    }

    deinit {
        whisper_free(ctx)
    }

    /// Domyślna liczba wątków — rdzenie wydajnościowe, maks. 8.
    public static var defaultThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Transkrybuje próbki 16 kHz mono Float32.
    /// - Parameters:
    ///   - samples: próbki audio.
    ///   - language: kod języka ("auto", "pl", "en", ...).
    ///   - translate: tłumacz na angielski zamiast transkrypcji.
    ///   - threads: liczba wątków.
    ///   - progress: opcjonalne wywołania zwrotne 0.0–1.0.
    ///   - shouldCancel: opcjonalne zapytanie wołane w trakcie; zwróć `true`, aby
    ///     natychmiast przerwać (whisper_full kończy się i metoda rzuca `.cancelled`).
    public func transcribe(
        samples: [Float],
        language: String = "auto",
        translate: Bool = false,
        threads: Int = WhisperEngine.defaultThreadCount,
        progress: ((Double) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> [TranscriptSegment] {

        guard !samples.isEmpty else { return [] }
        if shouldCancel?() == true { throw SkrybaError.cancelled }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = translate
        params.single_segment = false
        params.no_timestamps = false
        params.n_threads = Int32(threads)

        // Most do callbacku postępu (utrzymuj `box` żywym do końca whisper_full).
        let box = progress.map { ProgressBox($0) }
        if let box {
            params.progress_callback = { _, _, value, user in
                guard let user else { return }
                let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
                box.callback(Double(value) / 100.0)
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }

        // Most do callbacku anulowania (utrzymuj `abortBox` żywym do końca whisper_full).
        let abortBox = shouldCancel.map { AbortBox($0) }
        if let abortBox {
            params.abort_callback = { user in
                guard let user else { return false }
                return Unmanaged<AbortBox>.fromOpaque(user).takeUnretainedValue().shouldCancel()
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(abortBox).toOpaque()
        }

        let status: Int32 = language.withCString { langPtr in
            // Dla "auto" whisper sam wykrywa język i transkrybuje.
            // UWAGA: detect_language=true oznacza "tylko wykryj i zakończ" (0 segmentów),
            // dlatego musi zostać false.
            params.language = langPtr
            params.detect_language = false
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        withExtendedLifetime(box) {}
        withExtendedLifetime(abortBox) {}

        if shouldCancel?() == true { throw SkrybaError.cancelled }
        guard status == 0 else {
            throw SkrybaError.transcriptionFailed(Int(status))
        }

        let count = whisper_full_n_segments(ctx)
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(Int(count))
        for i in 0..<count {
            let textPtr = whisper_full_get_segment_text(ctx, i)
            let text = textPtr.map { String(cString: $0) } ?? ""
            // t0/t1 są w setnych częściach sekundy (jednostka = 10 ms).
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            segments.append(TranscriptSegment(text: text, start: t0, end: t1))
        }
        return segments
    }

    /// Informacja o backendzie (m.in. czy aktywny jest Metal/akceleracja).
    public static func systemInfo() -> String {
        whisper_print_system_info().map { String(cString: $0) } ?? ""
    }
}
