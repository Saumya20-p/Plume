import XCTest
@testable import Plume

final class PlumeTests: XCTestCase {
    @MainActor
    func testPhonemizerNewline() async throws {
        print("\n\n=== LOG START ===")
        let chunkText = "wistful.\n\nThe situation"
        print("INPUT CHUNK TEXT: [\(chunkText.replacingOccurrences(of: "\n", with: "\\n"))]")
        
        let service = KokoroTTSService.shared
        // Let's call the actor
        let actor = await service.getEngineActorSync()
        
        do {
            _ = try await actor.generateSingleChunk(
                chunkText: chunkText,
                chunkRange: chunkText.startIndex..<chunkText.endIndex,
                fullText: chunkText,
                currentTimeOffset: 0,
                format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!,
                settings: [:]
            )
        } catch {
            print("Error: \(error)")
        }
        print("=== LOG END ===\n\n")
    }
}
