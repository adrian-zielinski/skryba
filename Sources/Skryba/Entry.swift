import Foundation

/// Punkt wejścia. Tryb `--selftest` uruchamia transkrypcję bez okna (do testów
/// i CI), w przeciwnym razie startuje aplikacja okienkowa.
@main
struct SkrybaMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        SkrybaApp.main()
    }
}
