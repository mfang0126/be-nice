// swift-tools-version:6.0
// be-nice — AX probe (M0). Not the product shell yet; a standalone executable
// so we can measure real AX read/write behavior across apps before committing
// to the NSPanel/menu-bar design.
import PackageDescription

let package = Package(
    name: "be-nice-axprobe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "axprobe",
            path: "Sources/axprobe"
        ),
        // M0 menu-bar shell. LSUIElement app bundle metadata lives in
        // Support/Info.plist and is assembled by scripts/build-app.sh.
        .executableTarget(
            name: "benice",
            path: "Sources/benice"
        )
    ]
)
