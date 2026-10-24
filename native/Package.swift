// swift-tools-version: 6.0
import PackageDescription

// Voice Type Native, phase 1a: the dictation pipeline and a command-line tool, no app yet.
// See PLAN.md for where this is going and README.md for building and running it.
let package = Package(
    name: "VoiceTypeNative",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "voice-type-native", targets: ["voice-type-native"]),
    ],
    targets: [
        // ggml-org's prebuilt whisper.cpp, release b5454: the exact binary the benchmark's
        // whispercpp-bench measured. SwiftPM downloads it into .build, so no binaries go in git.
        // `swift package compute-checksum whisper-b5454-xcframework.zip` gives the checksum.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),

        // Everything that decides what gets typed, apart from the model itself: settings,
        // the word list prompt and its tokens, the no-speech gates, the loop guard,
        // corrections and WAV reading. No whisper or AppKit, so it's tested on its own.
        .target(name: "VoiceTypeCore"),

        // The only code that talks to whisper.cpp.
        .target(name: "VoiceTypeWhisper", dependencies: ["VoiceTypeCore", "whisper"]),

        .executableTarget(
            name: "voice-type-native",
            dependencies: ["VoiceTypeCore", "VoiceTypeWhisper"]
        ),

        .testTarget(
            name: "VoiceTypeCoreTests",
            dependencies: ["VoiceTypeCore"],
            resources: [.copy("Fixtures")]
        ),
        // Needs the real model, so each test skips itself when the model isn't there.
        .testTarget(
            name: "VoiceTypeWhisperTests",
            dependencies: ["VoiceTypeCore", "VoiceTypeWhisper"]
        ),
    ]
)
