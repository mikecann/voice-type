// swift-tools-version: 6.0
import PackageDescription

// Voice Type Native: the dictation pipeline, the menu bar app and its command line, in one
// executable. See PLAN.md for where this is going and README.md for building and running it.
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

        // Pixel work for screen-mark screenshots: ports of Pillow's resize, quantizer and PNG
        // encoding. Always optimised, even in debug builds, since unoptimised Swift takes
        // seconds over a Retina window, which the tests would feel.
        .target(name: "VoiceTypeImaging", swiftSettings: [.unsafeFlags(["-O"])]),

        // Everything that decides what gets typed, apart from the model itself: settings,
        // the word list prompt and its tokens, the no-speech gates, the loop guard,
        // corrections and WAV reading. No whisper or AppKit, so it's tested on its own.
        .target(name: "VoiceTypeCore", dependencies: ["VoiceTypeImaging"]),

        // The only code that talks to whisper.cpp.
        .target(name: "VoiceTypeWhisper", dependencies: ["VoiceTypeCore", "whisper"]),

        // Everything that touches the Mac: the keyboard tap, Core Audio, the pasteboard and
        // Accessibility, launchctl, the menu bar item and the pill. Kept thin; the decisions
        // are in VoiceTypeCore, behind the protocols these implement.
        // Swift 5 mode: AppKit, C callbacks and GCD queues that Swift 6's checker can't see.
        .target(name: "VoiceTypeMac", dependencies: ["VoiceTypeCore", "VoiceTypeWhisper"],
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // The app when launched as Voice Type Native.app, the command line otherwise.
        .executableTarget(
            name: "voice-type-native",
            dependencies: ["VoiceTypeCore", "VoiceTypeWhisper", "VoiceTypeMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "VoiceTypeCoreTests",
            dependencies: ["VoiceTypeCore", "VoiceTypeImaging"],
            resources: [.copy("Fixtures")]
        ),
        // Needs the real model, so each test skips itself when the model isn't there.
        .testTarget(
            name: "VoiceTypeWhisperTests",
            dependencies: ["VoiceTypeCore", "VoiceTypeWhisper"]
        ),
        // The Mac pieces that can be tested without hardware or permissions: resampling,
        // the ring buffer, launchctl output parsing. Nothing here opens a tap, the
        // microphone or the pasteboard.
        .testTarget(
            name: "VoiceTypeMacTests",
            dependencies: ["VoiceTypeCore", "VoiceTypeMac"]
        ),
    ]
)
