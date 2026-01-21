// swift-tools-version:6.0

// ============================================================================
// MARK: - Package Manifest for CommandTab
// ============================================================================
//
// This Swift Package defines a macOS window switcher application that provides
// a custom Command+Tab experience. The application intercepts keyboard events,
// enumerates visible windows, and allows users to quickly switch between them.
//
// IMPORTANT: Swift Package Manager produces an executable, not an .app bundle.
// To create a proper macOS application bundle, use the Scripts/bundle-app.sh
// script after building. This is necessary for:
//   - Menu bar presence (LSUIElement)
//   - Accessibility permission prompts
//   - Proper macOS application behavior
//
// Build Commands:
//   swift build              - Build debug executable
//   swift build -c release   - Build release executable
//   ./Scripts/bundle-app.sh  - Create .app bundle from release build
//
// ============================================================================

import PackageDescription

// ============================================================================
// MARK: - Package Definition
// ============================================================================

let package = Package(

    // ========================================================================
    // MARK: Package Identification
    // ========================================================================

    /// The name of the package and its primary product
    name: "CommandTab",

    // ========================================================================
    // MARK: Supported Platforms
    // ========================================================================

    /// This application requires macOS 15.0 (Sequoia) or later.
    /// The original Xcode project targeted macOS 26.2, which corresponds to
    /// a future macOS version. We use .v15 as the minimum supported version.
    platforms: [
        .macOS(.v15)
    ],

    // ========================================================================
    // MARK: Products
    // ========================================================================

    /// Products define what this package vends to clients.
    /// This package produces a single executable application.
    products: [
        .executable(
            name: "CommandTab",
            targets: ["CommandTab"]
        )
    ],

    // ========================================================================
    // MARK: Dependencies
    // ========================================================================

    /// External package dependencies required by this application.
    /// Currently none - the app uses raw CGEvent taps for keyboard shortcuts.
    /// The KeyboardShortcuts package was previously referenced but is not used.
    dependencies: [],

    // ========================================================================
    // MARK: Targets
    // ========================================================================

    /// Targets are the basic building blocks of a package.
    /// This package has a single executable target containing all application code.
    targets: [
        .executableTarget(
            name: "CommandTab",

            /// Dependencies for this target (none currently)
            dependencies: [],

            /// Path to the source files for this target
            path: "Sources/CommandTab",

            /// Resources to include with the target.
            /// The asset catalog is copied (not processed) because SPM cannot
            /// compile .xcassets directly. The bundle-app.sh script uses actool
            /// to compile assets when creating the .app bundle.
            resources: [
                .copy("Resources/Assets.xcassets")
            ],

            /// Swift compiler settings for this target
            swiftSettings: [
                /// Enable strict concurrency checking for safer async code
                .enableExperimentalFeature("StrictConcurrency"),

                /// Define DEBUG symbol in debug builds for conditional compilation
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ],

    // ========================================================================
    // MARK: Swift Language Mode
    // ========================================================================

    /// Use Swift 6 language mode for latest language features and safety checks
    swiftLanguageModes: [.v6]
)
