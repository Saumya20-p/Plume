import XCTest
import AVFoundation
@testable import Plume

final class PlumeTests: XCTestCase {
    @MainActor
    func testPhonemizerNewline() async throws {
        print("\n\n=== LOG START ===")
        let chunkText = "wistful.\n\nThe situation"
        print("INPUT CHUNK TEXT: [\(chunkText.replacingOccurrences(of: "\n", with: "\\n"))]")
        
        let service = KokoroTTSService.shared
        guard let actor = service.getEngineActorSync() else {
            print("Actor not available in test harness")
            return
        }
        
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let docID = UUID()
        let session = PlaybackGenerationSession(documentID: docID, voice: .kokoro(identifier: "af_heart"))
        let segmentID = DocumentSegmentID(documentID: docID, ordinal: 0, utf16Range: UTF16TextRange(location: 0, length: chunkText.utf16.count))
        let identity = GeneratedAudioChunkIdentity(session: session, segmentID: segmentID)
        
        do {
            _ = try await actor.generateSingleChunk(
                identity: identity,
                voiceIdentifier: "af_heart",
                chunkText: chunkText,
                chunkRange: chunkText.startIndex..<chunkText.endIndex,
                fullText: chunkText,
                currentTimeOffset: 0,
                format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!,
                settings: [:],
                destinationURL: dest
            )
        } catch {
            print("Error: \(error)")
        }
        print("=== LOG END ===\n\n")
    }
}
