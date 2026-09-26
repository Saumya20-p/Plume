import XCTest
@testable import Plume

final class PlaybackSessionContractTests: XCTestCase {
    func testSessionSnapshotsPrimaryAndFallbackIndependently() throws {
        let documentID = UUID()
        var preferences = VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "apple.fallback.one"
        )
        let session = try XCTUnwrap(
            PlaybackSessionContract(
                documentID: documentID,
                preferences: preferences,
                sourceUTF16Length: 100
            )
        )

        preferences = VoicePreferences(
            primary: .apple(identifier: "apple.primary.two"),
            fallbackAppleVoiceIdentifier: "apple.fallback.two"
        )

        XCTAssertEqual(session.documentID, documentID)
        XCTAssertEqual(session.primaryVoice, .kokoro(identifier: "af_heart"))
        XCTAssertEqual(session.fallbackAppleVoiceIdentifier, "apple.fallback.one")
        XCTAssertEqual(session.sourceUTF16Length, 100)
    }

    func testSourceLengthIsRequiredAndBoundsInitialCursor() throws {
        let preferences = testPreferences()
        XCTAssertNil(
            PlaybackSessionContract(
                documentID: UUID(),
                preferences: preferences,
                sourceUTF16Length: -1
            )
        )
        XCTAssertNil(
            PlaybackSessionContract(
                documentID: UUID(),
                preferences: preferences,
                sourceUTF16Length: 100,
                initialCursor: try cursor(segment: 0, offset: 101)
            )
        )

        var session = try XCTUnwrap(
            PlaybackSessionContract(
                documentID: UUID(),
                preferences: preferences,
                sourceUTF16Length: 100,
                initialCursor: try cursor(segment: 0, offset: 100)
            )
        )
        XCTAssertEqual(session.sourceCursor, try cursor(segment: 0, offset: 100))
        XCTAssertNil(
            session.beginCallback(
                for: .apple,
                utteranceID: UUID(),
                sourceBoundary: try cursor(segment: 0, offset: 101)
            )
        )
        XCTAssertFalse(session.seek(to: try cursor(segment: 0, offset: 101)))
    }

    func testSeekAndCancelRejectStaleCallbacksWithinSameSession() throws {
        let firstCursor = try cursor(segment: 0, offset: 0)
        let laterCursor = try cursor(segment: 1, offset: 12)
        var session = try makeSession(initialCursor: firstCursor)
        let firstToken = try XCTUnwrap(
            session.beginCallback(
                for: .apple,
                utteranceID: UUID(),
                sourceBoundary: laterCursor
            )
        )

        XCTAssertTrue(session.willSpeak(try cursor(segment: 0, offset: 8), callback: firstToken))
        XCTAssertTrue(session.seek(to: firstCursor))
        XCTAssertFalse(session.willSpeak(laterCursor, callback: firstToken))
        XCTAssertFalse(session.didFinish(at: laterCursor, callback: firstToken))

        // A seek intentionally clears buffered audio but retains ownership;
        // switching producers therefore requires an explicit release.
        XCTAssertTrue(session.releaseProducer(.apple))
        XCTAssertTrue(session.acquireProducer(.kokoro))
        let secondToken = try XCTUnwrap(
            session.beginCallback(
                for: .kokoro,
                utteranceID: UUID(),
                sourceBoundary: try cursor(segment: 1, offset: 20)
            )
        )
        XCTAssertTrue(session.cancel())
        XCTAssertFalse(session.didCancel(callback: secondToken))
    }

    func testCursorMonotonicityAllowsBackwardMovementOnlyForExplicitSeek() throws {
        var session = try makeSession()
        let first = try cursor(segment: 0, offset: 10)
        let backward = try cursor(segment: 0, offset: 4)
        let forward = try cursor(segment: 0, offset: 20)
        let token = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: forward)
        )

        XCTAssertTrue(session.willSpeak(first, callback: token))
        XCTAssertFalse(session.willSpeak(backward, callback: token))
        XCTAssertTrue(session.didFinish(at: forward, callback: token))
        XCTAssertEqual(session.committedCursor, forward)

        XCTAssertTrue(session.seek(to: backward))
        XCTAssertEqual(session.displayCursor, backward)
        XCTAssertEqual(session.committedCursor, backward)
    }

    func testWillSpeakIsDisplayOnlyDidFinishCommitsAndCancelDoesNotAdvance() throws {
        var session = try makeSession()
        let displayed = try cursor(segment: 0, offset: 8)
        let committed = try cursor(segment: 0, offset: 16)
        let firstToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: committed)
        )

        XCTAssertTrue(session.willSpeak(displayed, callback: firstToken))
        XCTAssertEqual(session.displayCursor, displayed)
        XCTAssertEqual(session.committedCursor, .beginning)
        XCTAssertTrue(session.didCancel(callback: firstToken))
        XCTAssertEqual(session.committedCursor, .beginning)

        let secondToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: committed)
        )
        XCTAssertTrue(session.willSpeak(committed, callback: secondToken))
        XCTAssertTrue(session.didFinish(at: committed, callback: secondToken))
        XCTAssertEqual(session.committedCursor, committed)
    }

    func testDesiredPlayDoesNotClaimActualActivityUntilProducerConfirms() throws {
        var session = try makeSession()
        session.requestPlay()
        XCTAssertEqual(session.desiredPlayIntent, .playing)
        XCTAssertEqual(session.actualActivity, .buffering)

        XCTAssertTrue(session.acquireProducer(.kokoro))
        let event = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        XCTAssertTrue(session.markProducerPlaying(.kokoro, event: event))
        XCTAssertEqual(session.actualActivity, .playing(.kokoro))
    }

    func testPauseAndInterruptionPreserveIntentAndValidBuffersWithoutUnexpectedPlay() throws {
        var session = try makeSession()
        session.requestPlay()
        XCTAssertTrue(session.acquireProducer(.kokoro))
        let event = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        XCTAssertTrue(session.markProducerPlaying(.kokoro, event: event))
        session.setValidBufferedAudio(true)

        session.pause()
        XCTAssertEqual(session.desiredPlayIntent, .paused)
        XCTAssertEqual(session.actualActivity, .paused)
        XCTAssertTrue(session.hasValidBufferedAudio)

        session.beginInterruption()
        XCTAssertEqual(session.desiredPlayIntent, .paused)
        XCTAssertEqual(session.actualActivity, .interrupted)
        XCTAssertTrue(session.hasValidBufferedAudio)
        XCTAssertTrue(session.endInterruption())
        XCTAssertEqual(session.actualActivity, .paused)

        session.requestPlay()
        XCTAssertEqual(session.desiredPlayIntent, .playing)
        XCTAssertEqual(session.actualActivity, .buffering)
        let resumedEvent = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        XCTAssertTrue(session.markProducerPlaying(.kokoro, event: resumedEvent))
        XCTAssertEqual(session.actualActivity, .playing(.kokoro))
    }

    func testInterruptionInvalidatesOldEventButRetainsValidBuffer() throws {
        var session = try makeSession()
        session.requestPlay()
        XCTAssertTrue(session.acquireProducer(.apple))
        let oldEvent = try XCTUnwrap(session.eventIdentity(for: .apple))
        XCTAssertTrue(session.markProducerPlaying(.apple, event: oldEvent))
        session.setValidBufferedAudio(true)

        session.beginInterruption()
        XCTAssertEqual(session.desiredPlayIntent, .playing)
        XCTAssertEqual(session.actualActivity, .interrupted)
        XCTAssertTrue(session.hasValidBufferedAudio)
        XCTAssertFalse(session.markProducerPlaying(.apple, event: oldEvent))

        XCTAssertTrue(session.endInterruption())
        XCTAssertEqual(session.actualActivity, .buffering)
        let resumedEvent = try XCTUnwrap(session.eventIdentity(for: .apple))
        XCTAssertTrue(session.markProducerPlaying(.apple, event: resumedEvent))
        XCTAssertEqual(session.actualActivity, .playing(.apple))
    }

    func testPreparationFailureDoesNotStopAudibleProducerAndUnderrunRespectsPause() throws {
        var session = try makeSession()
        session.requestPlay()
        XCTAssertTrue(session.acquireProducer(.apple))
        let appleEvent = try XCTUnwrap(session.eventIdentity(for: .apple))
        XCTAssertTrue(session.markProducerPlaying(.apple, event: appleEvent))
        let kokoroEvent = try XCTUnwrap(session.eventIdentity(for: .kokoro))

        XCTAssertTrue(session.setPreparationStatus(.preparing, event: kokoroEvent))
        XCTAssertTrue(session.setPreparationStatus(.failed, event: kokoroEvent))
        XCTAssertEqual(session.actualActivity, .playing(.apple))
        XCTAssertFalse(session.markUnderrun(event: kokoroEvent))
        XCTAssertEqual(session.actualActivity, .playing(.apple))

        session.pause()
        let pausedEvent = try XCTUnwrap(session.eventIdentity(for: .apple))
        XCTAssertTrue(session.markUnderrun(event: pausedEvent))
        XCTAssertEqual(session.actualActivity, .paused)
    }

    func testStalePreparationAndProducerEventsAreRejectedAfterSeek() throws {
        var session = try makeSession()
        let oldEvent = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        let oldGeneration = session.callbackGeneration
        XCTAssertTrue(session.seek(to: try cursor(segment: 0, offset: 4)))
        XCTAssertGreaterThan(session.callbackGeneration, oldGeneration)
        XCTAssertFalse(session.setPreparationStatus(.ready, event: oldEvent))
        XCTAssertFalse(session.markUnderrun(event: oldEvent))
    }

    func testOneProducerRequiresReleaseBeforeSwitching() throws {
        var session = try makeSession()
        XCTAssertTrue(session.acquireProducer(.kokoro))
        XCTAssertFalse(session.acquireProducer(.apple))
        XCTAssertTrue(session.releaseProducer(.kokoro))
        XCTAssertTrue(session.acquireProducer(.apple))
        XCTAssertEqual(session.activeProducer, .apple)
    }

    func testReleaseAndReacquireRejectsTheOldProducerEvent() throws {
        var session = try makeSession()
        XCTAssertTrue(session.acquireProducer(.kokoro))
        let oldEvent = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        XCTAssertTrue(session.releaseProducer(.kokoro))
        XCTAssertTrue(session.acquireProducer(.kokoro))
        XCTAssertFalse(session.markProducerPlaying(.kokoro, event: oldEvent))

        let newEvent = try XCTUnwrap(session.eventIdentity(for: .kokoro))
        XCTAssertTrue(session.markProducerPlaying(.kokoro, event: newEvent))
    }

    func testTerminalCompletionRequiresFinalBoundaryAndOccursExactlyOnce() throws {
        var session = try makeSession(sourceLength: 20)
        let nonFinal = try cursor(segment: 0, offset: 10)
        let nonFinalToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: nonFinal)
        )
        XCTAssertTrue(session.didFinish(at: nonFinal, callback: nonFinalToken))
        XCTAssertFalse(session.completeLogicalDocument(at: nonFinal, callback: nonFinalToken))
        XCTAssertEqual(session.lifecycle, .active)

        let final = try cursor(segment: 0, offset: 20)
        let finalToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: final)
        )
        XCTAssertFalse(session.completeLogicalDocument(at: nonFinal, callback: finalToken))
        XCTAssertEqual(session.lifecycle, .active)
        XCTAssertTrue(session.completeLogicalDocument(at: final, callback: finalToken))
        XCTAssertFalse(session.completeLogicalDocument(at: final, callback: finalToken))
        XCTAssertEqual(session.lifecycle, .completed)
        XCTAssertNil(session.activeProducer)
    }

    func testMultipleInFlightCallbacksCanBeQueuedAndFinishedSequentially() throws {
        var session = try makeSession(sourceLength: 30)
        let firstBoundary = try cursor(segment: 0, offset: 10)
        let secondBoundary = try cursor(segment: 1, offset: 20)

        let firstToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: firstBoundary)
        )
        let secondToken = try XCTUnwrap(
            session.beginCallback(for: .apple, utteranceID: UUID(), sourceBoundary: secondBoundary)
        )

        XCTAssertEqual(session.activeCallbacks.count, 2)
        XCTAssertEqual(session.activeCallback, firstToken)
        XCTAssertTrue(session.accepts(firstToken))
        XCTAssertTrue(session.accepts(secondToken))

        // Will speak on first token
        XCTAssertTrue(session.willSpeak(try cursor(segment: 0, offset: 5), callback: firstToken))

        // First token finishes
        XCTAssertTrue(session.didFinish(at: firstBoundary, callback: firstToken))
        XCTAssertEqual(session.activeCallbacks.count, 1)
        XCTAssertEqual(session.activeCallback, secondToken)
        XCTAssertFalse(session.accepts(firstToken))
        XCTAssertTrue(session.accepts(secondToken))

        // Will speak on second token
        XCTAssertTrue(session.willSpeak(try cursor(segment: 1, offset: 15), callback: secondToken))

        // Second token finishes
        XCTAssertTrue(session.didFinish(at: secondBoundary, callback: secondToken))
        XCTAssertEqual(session.activeCallbacks.count, 0)
        XCTAssertNil(session.activeCallback)
    }

    func testResolverUsesChosenThenSameLocaleThenValidatedSystemDefault() {
        let chosen = descriptor("chosen", language: "en-US", quality: .enhanced)
        let sameLocale = descriptor("same-locale", language: "en-US", quality: .premium)
        let otherLocale = descriptor("other-locale", language: "en-GB", quality: .premium)
        let systemDefault = candidate("system-default", language: "en-US", quality: .default)

        XCTAssertEqual(
            AppleSpeechVoiceResolver.resolve(
                preferredIdentifier: chosen.id,
                preferredLocale: chosen.language,
                eligibleVoices: [sameLocale, chosen],
                compatibleSystemDefault: systemDefault
            ),
            .chosen(chosen)
        )
        XCTAssertEqual(
            AppleSpeechVoiceResolver.resolve(
                preferredIdentifier: "missing",
                preferredLocale: "en-US",
                eligibleVoices: [otherLocale, sameLocale],
                compatibleSystemDefault: systemDefault
            ),
            .sameLocale(sameLocale)
        )
        XCTAssertEqual(
            AppleSpeechVoiceResolver.resolve(
                preferredIdentifier: "missing",
                preferredLocale: "en-GB",
                eligibleVoices: [],
                compatibleSystemDefault: systemDefault
            ),
            .compatibleSystemDefault(systemDefault)
        )
        XCTAssertNil(
            AppleSpeechVoiceResolver.resolve(
                preferredIdentifier: "missing",
                preferredLocale: "en-US",
                eligibleVoices: [],
                compatibleSystemDefault: systemDefault
            ).voice
        )
    }

    func testResolverFallsBackToHighestQualityWhenSameLocaleMissingOrNil() {
        let otherLocaleEnhanced = descriptor("other-enhanced", language: "en-GB", quality: .enhanced)
        let otherLocalePremium = descriptor("other-premium", language: "en-GB", quality: .premium)
        let systemDefault = candidate("system-default", language: "en-US", quality: .default)

        // Preferred voice missing, preferred locale en-US has no eligible voice, but en-GB premium/enhanced are available
        let result = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: "missing",
            preferredLocale: "en-US",
            eligibleVoices: [otherLocaleEnhanced, otherLocalePremium],
            compatibleSystemDefault: systemDefault
        )
        XCTAssertEqual(result, .highestQuality(otherLocalePremium))
        XCTAssertEqual(result.reason, .highestQuality)
        XCTAssertEqual(result.voice?.id, "other-premium")

        // No preferred identifier and no preferred locale (System Default fallback preference)
        let defaultFallback = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: nil,
            preferredLocale: nil,
            eligibleVoices: [otherLocaleEnhanced, otherLocalePremium],
            compatibleSystemDefault: systemDefault
        )
        XCTAssertEqual(defaultFallback, .highestQuality(otherLocalePremium))
        XCTAssertEqual(defaultFallback.reason, .highestQuality)
        XCTAssertEqual(defaultFallback.voice?.id, "other-premium")
    }

    func testResolverRejectsIncompatibleVoiceWhenPreferredLocaleNilOrDifferentLanguage() {
        let frenchPremium = descriptor("french-premium", language: "fr-FR", quality: .premium)
        let frenchEnhanced = descriptor("french-enhanced", language: "fr-FR", quality: .enhanced)
        let systemDefault = candidate("system-default", language: "en-US", quality: .default)

        // When preferred locale is nil, foreign voice is rejected in favor of English compatible system default
        let nilLocaleResult = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: nil,
            preferredLocale: nil,
            eligibleVoices: [frenchPremium, frenchEnhanced],
            compatibleSystemDefault: systemDefault
        )
        XCTAssertEqual(nilLocaleResult, .compatibleSystemDefault(systemDefault))
        XCTAssertEqual(nilLocaleResult.reason, .compatibleSystemDefault)
        XCTAssertNil(nilLocaleResult.voice)

        // When preferred locale is en-US, foreign voice is rejected in favor of English compatible system default
        let enUsResult = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: "missing",
            preferredLocale: "en-US",
            eligibleVoices: [frenchPremium],
            compatibleSystemDefault: systemDefault
        )
        XCTAssertEqual(enUsResult, .compatibleSystemDefault(systemDefault))
        XCTAssertEqual(enUsResult.reason, .compatibleSystemDefault)
        XCTAssertNil(enUsResult.voice)
    }

    func testResolverPrefersSameLocaleOverHigherQualityDifferentLocale() {
        let sameLocaleEnhanced = descriptor("us-enhanced", language: "en-US", quality: .enhanced)
        let otherLocalePremium = descriptor("gb-premium", language: "en-GB", quality: .premium)
        let systemDefault = candidate("system-default", language: "en-US", quality: .default)

        let result = AppleSpeechVoiceResolver.resolve(
            preferredIdentifier: nil,
            preferredLocale: "en-US",
            eligibleVoices: [otherLocalePremium, sameLocaleEnhanced],
            compatibleSystemDefault: systemDefault
        )
        XCTAssertEqual(result, .sameLocale(sameLocaleEnhanced))
        XCTAssertEqual(result.reason, .sameLocale)
        XCTAssertEqual(result.voice?.id, "us-enhanced")
    }

    func testResolverRejectsIncompatibleOrUnsafeSystemDefault() {
        let unsafeCandidates = [
            candidate("novelty", language: "en-US", quality: .default, novelty: true),
            candidate("personal", language: "en-US", quality: .default, personal: true),
            candidate("french", language: "fr-FR", quality: .default)
        ]

        for unsafe in unsafeCandidates {
            XCTAssertEqual(
                AppleSpeechVoiceResolver.resolve(
                    preferredIdentifier: "missing",
                    preferredLocale: "en-US",
                    eligibleVoices: [],
                    compatibleSystemDefault: unsafe
                ),
                .unavailable
            )
        }

        XCTAssertEqual(
            AppleSpeechVoiceResolver.resolve(
                preferredIdentifier: "missing",
                preferredLocale: "fr-FR",
                eligibleVoices: [],
                compatibleSystemDefault: candidate("english", language: "en-US", quality: .default)
            ),
            .unavailable
        )
    }

    func testUTF16RangeValidationRejectsNegativeOverflowAndOutOfBoundsInputs() {
        XCTAssertNotNil(
            UTF16TextRange.validated(location: 2, length: 3, withinUTF16Length: 5)
        )
        XCTAssertNil(
            UTF16TextRange.validated(location: -1, length: 1, withinUTF16Length: 5)
        )
        XCTAssertNil(
            UTF16TextRange.validated(location: 1, length: -1, withinUTF16Length: 5)
        )
        XCTAssertNil(
            UTF16TextRange.validated(location: Int.max, length: 1, withinUTF16Length: Int.max)
        )
        XCTAssertNil(
            UTF16TextRange.validated(location: 4, length: 2, withinUTF16Length: 5)
        )
        XCTAssertNil(
            UTF16TextRange.validated(location: 0, length: 0, withinUTF16Length: -1)
        )
    }

    func testStateMachineTransitionsViaRoutingEvents() throws {
        var sm = try XCTUnwrap(PlaybackStateMachine(sourceUTF16Length: 100))
        XCTAssertEqual(sm.playbackState, .idle)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.desiredPlayIntent, .paused)
        XCTAssertEqual(sm.lifecycle, .active)

        // Request Play -> desiredPlayIntent becomes playing, actualActivity transitions to buffering
        XCTAssertTrue(sm.send(.requestPlay))
        XCTAssertEqual(sm.desiredPlayIntent, .playing)
        XCTAssertEqual(sm.playbackState, .buffering)

        // Acquire producer
        XCTAssertTrue(sm.send(.acquireProducer(.apple)))
        XCTAssertEqual(sm.activeProducer, .apple)

        // Confirm producer playing
        XCTAssertTrue(sm.send(.confirmProducerPlaying(.apple)))
        XCTAssertEqual(sm.playbackState, .playing(.apple))

        // Pause
        XCTAssertTrue(sm.send(.pause))
        XCTAssertEqual(sm.desiredPlayIntent, .paused)
        XCTAssertEqual(sm.playbackState, .paused)

        // Resume play intent -> returns to buffering until producer confirms
        XCTAssertTrue(sm.send(.requestPlay))
        XCTAssertEqual(sm.playbackState, .buffering)
        XCTAssertTrue(sm.send(.confirmProducerPlaying(.apple)))
        XCTAssertEqual(sm.playbackState, .playing(.apple))

        // Interruption
        XCTAssertTrue(sm.send(.beginInterruption))
        XCTAssertEqual(sm.lifecycle, .suspended)
        XCTAssertEqual(sm.playbackState, .interrupted)

        // End interruption resumes desired play
        XCTAssertTrue(sm.send(.endInterruption))
        XCTAssertEqual(sm.lifecycle, .active)
        XCTAssertEqual(sm.playbackState, .buffering)
        XCTAssertTrue(sm.send(.confirmProducerPlaying(.apple)))
        XCTAssertEqual(sm.playbackState, .playing(.apple))
    }

    func testStateMachineUnderrunTriggers() throws {
        var sm = try XCTUnwrap(PlaybackStateMachine(sourceUTF16Length: 100))
        sm.send(.requestPlay)
        sm.send(.acquireProducer(.kokoro))
        let kokoroEvent = try XCTUnwrap(sm.eventIdentity(for: .kokoro))
        XCTAssertTrue(sm.send(.markProducerPlaying(.kokoro, event: kokoroEvent)))
        XCTAssertEqual(sm.playbackState, .playing(.kokoro))

        // Trigger underrun while playing -> transitions to buffering
        XCTAssertTrue(sm.send(.markUnderrun(event: kokoroEvent)))
        XCTAssertEqual(sm.playbackState, .buffering)
        XCTAssertEqual(sm.desiredPlayIntent, .playing)

        // Producer resumes
        XCTAssertTrue(sm.send(.markProducerPlaying(.kokoro, event: kokoroEvent)))
        XCTAssertEqual(sm.playbackState, .playing(.kokoro))

        // Pre-pause event is rejected because pause invalidates callbacks/events
        sm.send(.pause)
        XCTAssertEqual(sm.playbackState, .paused)
        XCTAssertFalse(sm.send(.markUnderrun(event: kokoroEvent)))

        // Current-epoch underrun while paused leaves state as paused
        let pausedKokoroEvent = try XCTUnwrap(sm.eventIdentity(for: .kokoro))
        XCTAssertTrue(sm.send(.markUnderrun(event: pausedKokoroEvent)))
        XCTAssertEqual(sm.playbackState, .paused)

        // Resume play and confirm producer playing
        sm.send(.requestPlay)
        XCTAssertTrue(sm.send(.confirmProducerPlaying(.kokoro)))
        XCTAssertEqual(sm.playbackState, .playing(.kokoro))

        // Underrun from mismatched producer is rejected
        let fakeEvent = PlaybackEventIdentity(
            sessionID: sm.sessionID,
            callbackGeneration: sm.callbackGeneration,
            producer: .apple
        )
        XCTAssertFalse(sm.send(.markUnderrun(event: fakeEvent)))
        XCTAssertEqual(sm.playbackState, .playing(.kokoro))

        // Underrun from stale generation after seek is rejected
        let beforeSeekEvent = try XCTUnwrap(sm.eventIdentity(for: .kokoro))
        let seekPos = try XCTUnwrap(DocumentCursor(segment: 0, offset: 20))
        XCTAssertTrue(sm.send(.seek(seekPos)))
        XCTAssertFalse(sm.send(.markUnderrun(event: beforeSeekEvent)))
    }

    func testStateMachineCancellation() throws {
        var sm = try XCTUnwrap(PlaybackStateMachine(sourceUTF16Length: 100))
        sm.send(.requestPlay)
        sm.send(.acquireProducer(.kokoro))
        sm.send(.setValidBufferedAudio(true))
        sm.send(.confirmProducerPlaying(.kokoro))
        XCTAssertEqual(sm.playbackState, .playing(.kokoro))
        XCTAssertTrue(sm.hasValidBufferedAudio)

        // Callback token created before cancellation
        let cursor = try XCTUnwrap(DocumentCursor(segment: 0, offset: 10))
        let token = try XCTUnwrap(sm.beginCallback(for: .kokoro, utteranceID: UUID(), sourceBoundary: cursor))

        // Cancel
        XCTAssertTrue(sm.send(.cancel))
        XCTAssertEqual(sm.lifecycle, .cancelled)
        XCTAssertEqual(sm.playbackState, .idle)
        XCTAssertNil(sm.activeProducer)
        XCTAssertFalse(sm.hasValidBufferedAudio)

        // Second cancel is idempotent / rejected
        XCTAssertFalse(sm.send(.cancel))

        // In-flight callback from before cancel is rejected
        XCTAssertFalse(sm.send(.didFinish(cursor, callback: token)))
        XCTAssertFalse(sm.send(.willSpeak(cursor, callback: token)))

        // Cannot request play, acquire producer, or seek after cancellation
        sm.send(.requestPlay)
        XCTAssertEqual(sm.playbackState, .idle)
        XCTAssertFalse(sm.send(.acquireProducer(.apple)))
        XCTAssertFalse(sm.send(.seek(cursor)))
    }

    func testDocumentCursorMonotonicityAndBoundaries() throws {
        // Initialization boundary validation
        XCTAssertNil(DocumentCursor(segment: -1, offset: 0))
        XCTAssertNil(DocumentCursor(segment: 0, offset: -1))
        XCTAssertNotNil(DocumentCursor(segment: 0, offset: 0))
        XCTAssertEqual(DocumentCursor.beginning, DocumentCursor(segment: 0, offset: 0))

        // Cursor ordering
        let c1 = try XCTUnwrap(DocumentCursor(segment: 0, offset: 10))
        let c2 = try XCTUnwrap(DocumentCursor(segment: 0, offset: 20))
        let c3 = try XCTUnwrap(DocumentCursor(segment: 1, offset: 20))
        XCTAssertTrue(c1 < c2)
        XCTAssertTrue(c2 < c3)
        XCTAssertFalse(c2 < c1)

        // Pure cursor state monotonicity
        var cursorState = PlaybackCursorState(initialCursor: c1)
        XCTAssertEqual(cursorState.displayCursor, c1)
        XCTAssertEqual(cursorState.committedCursor, c1)

        // Forward display advance succeeds
        XCTAssertTrue(cursorState.advanceDisplay(to: c2))
        XCTAssertEqual(cursorState.displayCursor, c2)
        XCTAssertEqual(cursorState.committedCursor, c1) // display does not commit

        // Backward display advance is rejected
        XCTAssertFalse(cursorState.advanceDisplay(to: c1))
        XCTAssertEqual(cursorState.displayCursor, c2)

        // Forward commit succeeds
        XCTAssertTrue(cursorState.commit(to: c2))
        XCTAssertEqual(cursorState.committedCursor, c2)

        // Backward commit is rejected
        XCTAssertFalse(cursorState.commit(to: c1))
        XCTAssertEqual(cursorState.committedCursor, c2)

        // Seek allows arbitrary backward movement
        cursorState.seek(to: c1)
        XCTAssertEqual(cursorState.displayCursor, c1)
        XCTAssertEqual(cursorState.committedCursor, c1)

        // Session integration with DocumentCursor
        var sm = try XCTUnwrap(PlaybackStateMachine(sourceUTF16Length: 50, initialCursor: c1))
        XCTAssertEqual(sm.documentCursor, c1)

        // Out-of-bounds seek is rejected
        let outOfBounds = try XCTUnwrap(DocumentCursor(segment: 0, offset: 51))
        XCTAssertFalse(sm.send(.seek(outOfBounds)))
        XCTAssertEqual(sm.documentCursor, c1)

        // Valid seek succeeds
        XCTAssertTrue(sm.send(.seek(c2)))
        XCTAssertEqual(sm.documentCursor, c2)
    }

    func testCommitBoundaryAndAdvanceDisplay() throws {
        var contract = try makeSession(sourceLength: 100)
        let c10 = try cursor(segment: 0, offset: 10)
        let c15 = try cursor(segment: 0, offset: 15)
        let c20 = try cursor(segment: 0, offset: 20)

        // Advance display cursor
        XCTAssertTrue(contract.send(.advanceDisplay(c15)))
        XCTAssertEqual(contract.displayCursor, c15)
        XCTAssertEqual(contract.committedCursor, .beginning)

        // Commit boundary moves committedCursor
        XCTAssertTrue(contract.send(.commitBoundary(c20)))
        XCTAssertEqual(contract.committedCursor, c20)

        // Monotonic check: older boundary commit rejected
        XCTAssertFalse(contract.send(.commitBoundary(c10)))
        XCTAssertEqual(contract.committedCursor, c20)
    }

    private func makeSession(
        sourceLength: Int = 100,
        initialCursor: PlaybackSourceCursor = .beginning
    ) throws -> PlaybackSessionContract {
        try XCTUnwrap(
            PlaybackSessionContract(
                documentID: UUID(),
                preferences: testPreferences(),
                sourceUTF16Length: sourceLength,
                initialCursor: initialCursor
            )
        )
    }

    private func testPreferences() -> VoicePreferences {
        VoicePreferences(
            primary: .kokoro(identifier: "af_heart"),
            fallbackAppleVoiceIdentifier: "apple.fallback"
        )
    }

    private func cursor(segment: Int, offset: Int) throws -> PlaybackSourceCursor {
        try XCTUnwrap(PlaybackSourceCursor(segmentOrdinal: segment, globalUTF16Offset: offset))
    }

    private func descriptor(
        _ id: String,
        language: String,
        quality: AppleSpeechVoiceQuality
    ) -> AppleSpeechVoiceDescriptor {
        AppleSpeechVoiceDescriptor(id: id, name: id, language: language, quality: quality)
    }

    private func candidate(
        _ id: String,
        language: String,
        quality: AppleSpeechVoiceCandidateQuality,
        novelty: Bool = false,
        personal: Bool = false
    ) -> AppleSpeechVoiceCandidate {
        AppleSpeechVoiceCandidate(
            identifier: id,
            name: id,
            language: language,
            quality: quality,
            isNoveltyVoice: novelty,
            isPersonalVoice: personal
        )
    }
}
