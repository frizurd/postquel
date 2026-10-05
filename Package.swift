// swift-tools-version: 6.0
import PackageDescription

// libpq location. Defaults to Postgres.app; override with e.g.
// LIBPQ_PREFIX=/opt/homebrew/opt/libpq swift build
let libpqPrefix = Context.environment["LIBPQ_PREFIX"] ?? "/Applications/Postgres.app/Contents/Versions/latest"

let package = Package(
    name: "Postquel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Postquel", targets: ["Postquel"])
    ],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "Sources/CLibPQ"),
        .executableTarget(
            name: "Postquel",
            dependencies: ["CLibPQ"],
            path: "Sources/Postquel",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(libpqPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(libpqPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(libpqPrefix)/lib"])
            ]
        ),
    ]
)
