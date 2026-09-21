import Foundation

nonisolated struct UTF16TextRange: Codable, Hashable, Sendable {
    let location: Int
    let length: Int

    var upperBound: Int {
        location + length
    }

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

nonisolated struct DocumentSegmentID: Codable, Hashable, Sendable {
    let documentID: UUID
    let ordinal: Int
    let utf16Range: UTF16TextRange
}

nonisolated struct PlaybackGenerationSession: Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let voice: PlaybackVoiceID

    init(id: UUID = UUID(), documentID: UUID, voice: PlaybackVoiceID) {
        self.id = id
        self.documentID = documentID
        self.voice = voice
    }
}

nonisolated struct GeneratedAudioChunkIdentity: Equatable, Sendable {
    let sessionID: UUID
    let documentID: UUID
    let segmentID: DocumentSegmentID
    let voice: PlaybackVoiceID

    init(session: PlaybackGenerationSession, segmentID: DocumentSegmentID) {
        self.sessionID = session.id
        self.documentID = session.documentID
        self.segmentID = segmentID
        self.voice = session.voice
    }
}

nonisolated enum PlaybackQueueItemIdentity: Equatable, Sendable {
    case generated(GeneratedAudioChunkIdentity)
    case legacy(documentID: UUID)
}

nonisolated struct PlaybackGenerationGate: Sendable {
    private(set) var activeSession: PlaybackGenerationSession?

    mutating func activate(_ session: PlaybackGenerationSession) {
        activeSession = session
    }

    mutating func invalidate() {
        activeSession = nil
    }

    func accepts(_ identity: GeneratedAudioChunkIdentity, currentDocumentID: UUID?) -> Bool {
        guard let activeSession, let currentDocumentID else { return false }
        return identity.sessionID == activeSession.id
            && identity.documentID == activeSession.documentID
            && identity.documentID == currentDocumentID
            && identity.segmentID.documentID == activeSession.documentID
            && identity.voice == activeSession.voice
    }

    func isActive(sessionID: UUID) -> Bool {
        activeSession?.id == sessionID
    }

    func matches(sessionID: UUID, documentID: UUID?) -> Bool {
        guard let activeSession, let documentID else { return false }
        return activeSession.id == sessionID && activeSession.documentID == documentID
    }
}

nonisolated enum PlaybackGenerationRunEvent: Equatable, Sendable {
    case work(sessionID: UUID)
    case enqueue(sessionID: UUID)
    case failure(sessionID: UUID)
    case completion(sessionID: UUID)
    case cleanup(sessionID: UUID)

    var sessionID: UUID {
        switch self {
        case .work(let sessionID),
             .enqueue(let sessionID),
             .failure(let sessionID),
             .completion(let sessionID),
             .cleanup(let sessionID):
            return sessionID
        }
    }
}

nonisolated struct PlaybackGenerationRunState: Sendable {
    private(set) var activeSessionID: UUID?

    mutating func activate(sessionID: UUID) {
        activeSessionID = sessionID
    }

    func accepts(_ event: PlaybackGenerationRunEvent) -> Bool {
        activeSessionID == event.sessionID
    }

    mutating func finish(sessionID: UUID) -> Bool {
        guard accepts(.completion(sessionID: sessionID)) else { return false }
        activeSessionID = nil
        return true
    }

    mutating func invalidateCurrent() -> UUID? {
        defer { activeSessionID = nil }
        return activeSessionID
    }
}

@MainActor
enum KokoroGenerationSessionFactory {
    static func make(documentID: UUID, defaults: UserDefaults) -> PlaybackGenerationSession {
        let voiceIdentifier = defaults.string(forKey: "kokoroVoice") ?? "af_heart"
        return PlaybackGenerationSession(
            documentID: documentID,
            voice: .kokoro(identifier: voiceIdentifier)
        )
    }
}
