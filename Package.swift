// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClassicCompanion",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        // 纯逻辑：导航分类、朗读分段、日志脱敏。无 AppKit/WebKit 依赖，可单元测试。
        .target(name: "CompanionCore"),
        // 界面文字在 Resources/<语言>.lproj。swift build 生成 ClassicCompanion_ClassicCompanion.bundle，
        // build-app.sh 把它复制到 Contents/Resources/，由 L10n 查找（不用 Bundle.module，见 Localization.swift）。
        .executableTarget(
            name: "ClassicCompanion",
            dependencies: ["CompanionCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ClassicCompanionTests", dependencies: ["ClassicCompanion"]),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"]
        ),
    ]
)
