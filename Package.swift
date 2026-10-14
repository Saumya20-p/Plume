// swift-tools-version: 6.0
import PackageDescription

// Phase 3A's host harness deliberately names each source file. The target is
// built from the app's pure contracts in place; it does not copy or stub
// runtime/MLX sources into a second implementation.
let package = Package(
    name: "PlumeHostHarness",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Plume", targets: ["Plume"])
    ],
    targets: [
        .target(
            name: "Plume",
            path: "Plume/Plume",
            exclude: [".DS_Store", "Assets.xcassets"],
            sources: [
                "PlaybackVoice.swift",
                "PlaybackGenerationIdentity.swift",
                "PlaybackSessionContract.swift",
                "AppleSpeechVoiceCatalog.swift",
                "AudioProducerProtocol.swift",
                "AppleSpeechProducer.swift",
                "AudioCacheStore.swift",
                "StatisticsRange.swift",
                "ReaderFont.swift",
                "ReaderFollowContract.swift",
                "ImportContracts.swift",
                "LibrarySearchContracts.swift"
            ]
        ),
        .testTarget(
            name: "PlumeHostTests",
            dependencies: ["Plume"],
            path: "Plume/PlumeTests",
            exclude: ["KokoroPlaybackFoundationTests.swift", "PlumeTests.swift", "QueueDeletionTests.swift", "PlaybackSeekLifecycleTests.swift"],
            sources: [
                "PlaybackVoiceFoundationTests.swift",
                "PlaybackSessionContractTests.swift",
                "AppleSpeechProducerTests.swift",
                "UIExperimentTests.swift",
                "ReaderContractsTests.swift",
                "ImportLibraryContractTests.swift"
            ]
        )
    ]
)
