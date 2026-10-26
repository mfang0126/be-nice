// swift-tools-version:6.0
// be-nice — macOS menu-bar app (benice). LSUIElement bundle metadata lives in
// Support/Info.plist and is assembled by scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "be-nice-axprobe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "benice",
            path: "Sources/benice"
        )
    ]
)
