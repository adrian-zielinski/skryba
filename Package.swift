// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skryba",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkrybaKit", targets: ["SkrybaKit"]),
        .executable(name: "skryba", targets: ["Skryba"]),
        .executable(name: "skryba-cli", targets: ["skryba-cli"]),
        .executable(name: "skryba-tests", targets: ["skryba-tests"]),
    ],
    targets: [
        // Silnik whisper.cpp (v1.9.1) jako wkompilowany framework z akceleracją Metal.
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),

        // Rdzeń: dekodowanie audio, silnik, modele, zapis transkrypcji.
        .target(
            name: "SkrybaKit",
            dependencies: ["whisper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Aplikacja okienkowa (SwiftUI).
        .executableTarget(
            name: "Skryba",
            dependencies: ["SkrybaKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Narzędzie wiersza poleceń.
        .executableTarget(
            name: "skryba-cli",
            dependencies: ["SkrybaKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Testy rdzenia jako wykonywalny runner (działa też bez pełnego Xcode,
        // gdzie XCTest/swift-testing są niedostępne). Uruchom: swift run skryba-tests
        .executableTarget(
            name: "skryba-tests",
            dependencies: ["SkrybaKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
