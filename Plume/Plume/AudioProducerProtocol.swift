import Foundation

@MainActor
protocol AudioProducerDelegate: AnyObject {
    func producerDidStart(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity)
    func producerWillSpeak(
        _ producer: any AudioProducerProtocol,
        callback: PlaybackCallbackIdentity,
        globalRange: UTF16TextRange
    )
    func producerDidFinish(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity)
    func producerDidCancel(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity)
}

extension AudioProducerDelegate {
    func producerDidStart(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {}
    func producerWillSpeak(
        _ producer: any AudioProducerProtocol,
        callback: PlaybackCallbackIdentity,
        globalRange: UTF16TextRange
    ) {}
    func producerDidFinish(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {}
    func producerDidCancel(_ producer: any AudioProducerProtocol, callback: PlaybackCallbackIdentity) {}
}

nonisolated enum AudioProducerEvent: Equatable, Sendable {
    case didStart(PlaybackCallbackIdentity)
    case willSpeak(PlaybackCallbackIdentity, UTF16TextRange)
    case didFinish(PlaybackCallbackIdentity)
    case didCancel(PlaybackCallbackIdentity)
}

@MainActor
protocol AudioProducerProtocol: AnyObject {
    var producerType: PlaybackProducer { get }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var generationID: UInt64 { get }

    var delegate: (any AudioProducerDelegate)? { get set }
    var onDidStart: ((PlaybackCallbackIdentity) -> Void)? { get set }
    var onWillSpeak: ((PlaybackCallbackIdentity, UTF16TextRange) -> Void)? { get set }
    var onDidFinish: ((PlaybackCallbackIdentity) -> Void)? { get set }
    var onDidCancel: ((PlaybackCallbackIdentity) -> Void)? { get set }

    func pause()
    func resume()
    func stop()
    func seek(to cursor: PlaybackSourceCursor)
    func reset()
    func activateAudioSession() throws
}
