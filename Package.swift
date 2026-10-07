// swift-tools-version:6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let deps = "\(root)/.deps/install"
let includeFlags = ["-I\(deps)/headers"]
let cmongocSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-DMONGOC_STATIC", "-Xcc", "-DBSON_STATIC"] + includeFlags.flatMap { ["-Xcc", $0] }),
]

let package = Package(
    name: "RoboTribute",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CMongoC",
            path: "Sources/CMongoC",
            cSettings: [
                .define("MONGOC_STATIC"),
                .define("BSON_STATIC"),
                .unsafeFlags(includeFlags),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(deps)/lib"]),
                .linkedLibrary("mongoc2"),
                .linkedLibrary("bson2"),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "CJSCPrivate",
            path: "Sources/CJSCPrivate",
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(
            name: "RoboTribute",
            dependencies: ["CMongoC", "CJSCPrivate"],
            path: "Sources/RoboTribute",
            resources: [.copy("Resources")],
            swiftSettings: cmongocSwiftSettings + [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "RoboTributeTests",
            dependencies: ["RoboTribute"],
            path: "Tests/RoboTributeTests",
            swiftSettings: cmongocSwiftSettings
        ),
    ]
)
