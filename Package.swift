// swift-tools-version: 5.8
import PackageDescription
let package = Package(
    name: "BooksPresence",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BooksPresence", targets: ["BooksPresence"]),
        .executable(name: "books-diagnostic", targets: ["BooksDiagnostic"]),
        .library(name: "BooksCore", targets: ["BooksCore"]),
        .library(name: "BooksPlatform", targets: ["BooksPlatform"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "BooksCore", dependencies: ["CSQLite"]),
        .target(name: "BooksPlatform", dependencies: ["BooksCore", "CSQLite"]),
        .executableTarget(name: "BooksPresence", dependencies: ["BooksCore", "BooksPlatform"]),
        .executableTarget(name: "BooksDiagnostic", dependencies: ["BooksPlatform"]),
        .testTarget(name: "BooksCoreTests", dependencies: ["BooksCore"]),
        .testTarget(name: "BooksPlatformTests", dependencies: ["BooksPlatform"])
    ]
)
