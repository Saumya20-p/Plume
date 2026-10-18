import Foundation
import NaturalLanguage
import SwiftUI
import Testing
import UIKit
@testable import Plume

struct ReaderSentenceHighlightTests {
    @Test(arguments: [
        ("was. After", "was", "was."),
        ("was. After", ".", "was."),
        ("was. After", "After", "After"),
        ("one, two", ",", "one,"),
        ("word,Next", "word", "word,"),
        ("word,” Next", "word", "word,”"),
        ("was.” Next", "”", "was.”"),
        ("\"Hello,\" Next", "Hello", "\"Hello,\""),
        ("'hello'Next", "hello", "'hello'"),
        ("was.“After", "was", "was."),
        ("was.\"After", "was", "was."),
        ("Wait... Next", "..", "Wait..."),
        ("Wait… Next", "…", "Wait…"),
        ("can't. Next", "can't", "can't."),
        ("mother-in-law. Next", "mother-in-law", "mother-in-law."),
        ("3.14. Next", "3.14", "3.14."),
        ("cafe\u{301}! Next", "cafe\u{301}", "cafe\u{301}!"),
        ("👩🏽‍🚀! Next", "!", "👩🏽‍🚀!"),
        ("word — next", "word", "word"),
        ("word — next", "—", "—"),
        ("word—Next", "word", "word—"),
        ("word—Next", "—", "word—"),
        ("word\nNext", "word", "word")
    ])
    func visualWordIncludesOnlyItsAttachedPunctuation(text: String, marker: String, expected: String) {
        let source = text as NSString
        let original = source.range(of: marker)
        var selection = ReaderVisualWordSelection()
        let visual = selection.resolve(marker: original, text: source)
        #expect(visual == source.range(of: expected))
        #expect(original == source.range(of: marker))
    }

    @Test func punctuationUpdatesHoldTheWordAndResetDoesNotLeakAcrossChapters() {
        let source: NSString = "was... After"
        var selection = ReaderVisualWordSelection()
        let combined = selection.resolve(marker: source.range(of: "was"), text: source)
        for index in 3..<6 {
            let punctuation = NSRange(location: index, length: 1)
            let visual = selection.resolve(marker: punctuation, text: source)
            #expect(visual == combined)
        }
        let next = selection.resolve(marker: source.range(of: "After"), text: source)
        #expect(next == source.range(of: "After"))
        let missing = selection.resolve(marker: nil, text: source)
        #expect(missing == nil)
        #expect(selection.current == nil)
        selection.reset()
        let changed: NSString = "new! chapter"
        let newWord = selection.resolve(marker: NSRange(location: 0, length: 3), text: changed)
        #expect(newWord == changed.range(of: "new!"))
        let invalid = selection.resolve(marker: NSRange(location: NSNotFound, length: 1), text: changed)
        #expect(invalid == nil)
    }

    @Test(arguments: [
        "\"Hello there!\" she said. \"Goodbye.\"",
        "Dr. Smith met J. R. Jones. They paid 3.14 dollars.",
        "Wait... really? Yes… perhaps. Next sentence!",
        "First sentence. Second sentence! An unpunctuated ending",
        "  👩🏽‍🚀 says cafe\u{301}.\n\nAnother chapter line.  ",
        "Unpunctuated ending", "", " \n\t "
    ])
    func indexPreservesNativeBoundariesAndOriginalUTF16(text: String) async throws {
        let revision = ReaderSentenceRevision(documentID: UUID(), revision: 1)
        let index = try await ReaderSentenceIndexer().index(text: text, revision: revision)
        // Ambiguous prose deliberately follows the OS tokenizer, including quote marks,
        // abbreviations and ellipses. This oracle catches preprocessing/period splitting.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let source = text as NSString
        var expected: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let trimmed = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                expected.append(source.range(of: trimmed, range: NSRange(range, in: text)))
            }
            return true
        }
        #expect(index.revision == revision)
        #expect(index.ranges == expected)
        for range in index.ranges {
            #expect(ReaderHighlightRanges.isValid(range, length: source.length))
            #expect(index.sentence(containing: range.location) == range)
            #expect(index.sentence(containing: NSMaxRange(range) - 1) == range)
        }
        #expect(index.sentence(containing: -1) == nil)
        #expect(index.sentence(containing: source.length) == nil)
    }

    @Test func pendingIndexResolvesLatestWordAndNeverFallsBackToParagraph() async throws {
        let source: NSString = "First sentence. Second sentence!"
        let revision = ReaderSentenceRevision(documentID: UUID(), revision: 1)
        var selection = ReaderSentenceSelection()
        selection.reset(to: revision)
        let first = source.range(of: "First")
        let second = source.range(of: "Second")
        #expect(selection.resolve(word: first, text: source) == nil)
        let index = try await ReaderSentenceIndexer().index(text: source as String, revision: revision)
        let accepted = selection.accept(index)
        #expect(accepted)
        let latest = selection.resolve(word: second, text: source)
        #expect(latest == source.range(of: "Second sentence!"))
        #expect(selection.resolve(word: source.range(of: "sentence!"), text: source) == latest)
        #expect(selection.resolve(word: NSRange(location: 15, length: 1), text: source) == nil)
        // Select by the first non-whitespace character, even across a boundary.
        #expect(selection.resolve(word: NSRange(location: 15, length: 7), text: source) == latest)
        #expect(selection.resolve(word: nil, text: source) == nil)
        var unmapped = ReaderSentenceSelection()
        unmapped.reset(to: revision)
        let acceptedPartialIndex = unmapped.accept(ReaderSentenceIndex(revision: revision, ranges: [source.range(of: "First sentence.")]))
        #expect(acceptedPartialIndex)
        #expect(unmapped.resolve(word: second, text: source) == nil)
    }

    @Test func chapterAndTextRevisionsRejectStaleResultsIncludingAToBToA() async throws {
        let document = UUID()
        let original = ReaderSentenceRevision(documentID: document, revision: 1)
        let other = ReaderSentenceRevision(documentID: UUID(), revision: 2)
        let returned = ReaderSentenceRevision(documentID: document, revision: 3)
        let index = try await ReaderSentenceIndexer().index(text: "Original chapter.", revision: original)
        var selection = ReaderSentenceSelection()
        selection.reset(to: original)
        let acceptedOriginal = selection.accept(index)
        #expect(acceptedOriginal)
        selection.reset(to: other)
        let acceptedOtherChapter = selection.accept(index)
        #expect(!acceptedOtherChapter)
        #expect(selection.current == nil)
        #expect(selection.index == nil)
        selection.reset(to: returned)
        let acceptedPriorRevision = selection.accept(index)
        #expect(!acceptedPriorRevision)
        selection.reset(to: nil) // Dismantling rejects even the otherwise-current revision.
        let late = ReaderSentenceIndex(revision: returned, ranges: index.ranges)
        let acceptedAfterDismantling = selection.accept(late)
        #expect(!acceptedAfterDismantling)
    }

    @Test func cancellationDoesNotReturnAPartialIndex() async {
        let worker = ReaderSentenceIndexer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.index(text: "A sentence. Another sentence.",
                                          revision: ReaderSentenceRevision(documentID: UUID(), revision: 1))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func composedCharactersExpandOnlyForDrawingAndInvalidRangesAreSafe() {
        let source: NSString = "👩🏽‍🚀 cafe\u{301}."
        let emojiMarker = NSRange(location: 2, length: 1)
        #expect(ReaderHighlightRanges.drawingRange(emojiMarker, text: source) == source.range(of: "👩🏽‍🚀"))
        #expect(emojiMarker == NSRange(location: 2, length: 1))
        let combining = source.range(of: "\u{301}")
        #expect(ReaderHighlightRanges.drawingRange(combining, text: source) == source.range(of: "e\u{301}"))
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                      NSRange(location: 0, length: -1), NSRange(location: 0, length: 0),
                      NSRange(location: source.length, length: 1), NSRange(location: 2, length: Int.max)] {
            #expect(!ReaderHighlightRanges.isValid(range, length: source.length))
            #expect(ReaderHighlightRanges.drawingRange(range, text: source) == nil)
            #expect(ReaderHighlightRanges.firstContent(in: range, text: source) == nil)
        }
    }
}

@MainActor struct ReaderHighlightRenderingTests {
    @Test(arguments: [0.2, 3.9, 4.0, 4.1] as [CGFloat])
    func adjacentSentenceEdgesExtendOnlyWithinTolerance(difference: CGFloat) {
        let original = [sentenceFragment(left: 10, right: 200, line: 0),
                        sentenceFragment(left: 10, right: 200 - difference, line: 1)]
        let aligned = ReaderHighlightGeometry.alignedSentenceFragments(original, tolerance: 4)
        let expected = difference <= 4 ? CGFloat(200) : 200 - difference
        #expect(aligned[1].rect.maxX == expected)
        for index in original.indices {
            #expect(aligned[index].rect.minX <= original[index].rect.minX)
            #expect(aligned[index].rect.maxX >= original[index].rect.maxX)
            #expect(aligned[index].rect.minY == original[index].rect.minY)
            #expect(aligned[index].rect.height == original[index].rect.height)
            #expect(aligned[index].unpaddedRect == original[index].unpaddedRect)
        }
    }

    @Test func toleranceScalesWithFontAndIsBounded() {
        let cases: [(CGFloat, CGFloat)] = [(8, 3), (15, 3), (20, 4), (25, 5), (40, 6)]
        for (font, expected) in cases {
            #expect(ReaderHighlightGeometry.sentenceEdgeTolerance(fontSize: font) == expected)
        }
    }

    @Test func alignmentGroupsDoNotAccumulateAStaircase() {
        let original = [sentenceFragment(left: 10, right: 200, line: 0),
                        sentenceFragment(left: 10, right: 203, line: 1),
                        sentenceFragment(left: 10, right: 206, line: 2)]
        let aligned = ReaderHighlightGeometry.alignedSentenceFragments(original, tolerance: 4)
        #expect(aligned.map { $0.rect.maxX } == [203, 203, 206])
        for index in original.indices {
            #expect(aligned[index].rect.maxX - original[index].rect.maxX <= 4)
        }
    }

    @Test func alignmentPreservesPartialFirstAndShortFinalLines() {
        let original = [sentenceFragment(left: 80, right: 200, line: 0),
                        sentenceFragment(left: 10, right: 198, line: 1),
                        sentenceFragment(left: 10, right: 60, line: 2)]
        let aligned = ReaderHighlightGeometry.alignedSentenceFragments(original, tolerance: 4)
        #expect(aligned.map { $0.rect.minX } == [80, 10, 10])
        #expect(aligned.map { $0.rect.maxX } == [200, 200, 60])
        let leftEdges = [sentenceFragment(left: 10, right: 200, line: 0),
                         sentenceFragment(left: 13, right: 200, line: 1)]
        let leftAligned = ReaderHighlightGeometry.alignedSentenceFragments(leftEdges, tolerance: 4)
        #expect(leftAligned.map { $0.rect.minX } == [10, 10])
    }

    @Test func expansionStopsBeforeOtherSentenceTextAndContainerEdges() {
        let original = [sentenceFragment(left: 10, right: 200, line: 0),
                        sentenceFragment(left: 12, right: 198, line: 1, bounds: 11...199)]
        let aligned = ReaderHighlightGeometry.alignedSentenceFragments(original, tolerance: 4)
        #expect(aligned.map(\.rect) == original.map(\.rect))
        let missing = [original[0], sentenceFragment(left: 12, right: 198, line: 1, bounds: nil)]
        let unchanged = ReaderHighlightGeometry.alignedSentenceFragments(missing, tolerance: 4)
        #expect(unchanged.map(\.rect) == missing.map(\.rect))
        // A blocked left edge on the longer reference line must not prevent a safe right merge.
        let independent = [sentenceFragment(left: 10, right: 200, line: 0, bounds: 12...300),
                           sentenceFragment(left: 10, right: 198, line: 1)]
        let rightAligned = ReaderHighlightGeometry.alignedSentenceFragments(independent, tolerance: 4)
        #expect(rightAligned.map { $0.rect.maxX } == [200, 200])
    }

    @Test func expansionSafetyUsesNearestObstaclesAndPixelClearance() throws {
        let rect = CGRect(x: 100, y: 0, width: 100, height: 24)
        let container = CGRect(x: 0, y: 0, width: 320, height: 300)
        let bounds = try #require(ReaderHighlightGeometry.sentenceExpansionBounds(for: rect, containerBounds: container,
            obstacles: [CGRect(x: 40, y: 0, width: 58, height: 24), CGRect(x: 204, y: 0, width: 40, height: 24),
                        CGRect(x: 150, y: 28, width: 30, height: 24)], clearance: 1.0 / 3))
        #expect(bounds.contains(99))
        #expect(bounds.contains(203))
        #expect(!bounds.contains(98))
        #expect(!bounds.contains(204))
        let uncertain = ReaderHighlightGeometry.sentenceExpansionBounds(for: rect, containerBounds: container,
            obstacles: [CGRect(x: 150, y: 0, width: 30, height: 24)], clearance: 1.0 / 3)
        #expect(uncertain == nil)
        let free = try #require(ReaderHighlightGeometry.sentenceExpansionBounds(for: rect, containerBounds: container,
            obstacles: [], clearance: 1.0 / 3))
        #expect(free == (0...320))
    }

    @Test func hardBreaksAndAmbiguousBidirectionalRunsDoNotAlign() {
        var hardBreak = sentenceFragment(left: 10, right: 200, line: 0)
        hardBreak = ReaderHighlightFragment(rect: hardBreak.rect, line: 0, joinsNext: false,
            unpaddedRect: hardBreak.unpaddedRect, horizontalExpansionBounds: hardBreak.horizontalExpansionBounds)
        let original = [hardBreak, sentenceFragment(left: 12, right: 198, line: 1)]
        let aligned = ReaderHighlightGeometry.alignedSentenceFragments(original, tolerance: 4)
        #expect(aligned.map(\.rect) == original.map(\.rect))
        let bidi = [sentenceFragment(left: 10, right: 100, line: 0),
                    sentenceFragment(left: 110, right: 200, line: 0),
                    sentenceFragment(left: 10, right: 198, line: 1)]
        let separate = ReaderHighlightGeometry.alignedSentenceFragments(bidi, tolerance: 4)
        #expect(separate.map(\.rect) == bidi.map(\.rect))
    }

    private func sentenceFragment(left: CGFloat, right: CGFloat, line: Int,
                                  bounds: ClosedRange<CGFloat>? = 0...320) -> ReaderHighlightFragment {
        let rect = CGRect(x: left, y: CGFloat(line) * 28, width: right - left, height: 24)
        return ReaderHighlightFragment(rect: rect, line: line, joinsNext: true,
                                       unpaddedRect: rect, horizontalExpansionBounds: bounds)
    }

    @Test func sentenceContourSmoothsSubpixelStepsWithoutJoiningDisconnectedRuns() {
        let fragments = [
            ReaderHighlightFragment(rect: CGRect(x: 10, y: 10, width: 150, height: 24), line: 0, joinsNext: true,
                                    horizontalExpansionBounds: 0...220),
            ReaderHighlightFragment(rect: CGRect(x: 10.2, y: 35, width: 100, height: 24), line: 1, joinsNext: false,
                                    horizontalExpansionBounds: 0...220),
            ReaderHighlightFragment(rect: CGRect(x: 180, y: 35, width: 30, height: 24), line: 1, joinsNext: false)
        ]
        let path = ReaderHighlightGeometry.sentenceContour(fragments: fragments, radius: 6, displayScale: 3)
        #expect(path.contains(CGPoint(x: 60, y: 34.5)))
        #expect(!path.contains(CGPoint(x: 170, y: 40)))
        #expect(!path.contains(CGPoint(x: 10.5, y: 10.5)))
        var curves = 0
        path.applyWithBlock { if $0.pointee.type == .addQuadCurveToPoint { curves += 1 } }
        #expect(curves >= 8)
        // An inward step is rounded outward into its notch, instead of staying a sharp elbow.
        #expect(path.contains(CGPoint(x: 111, y: 35)))
        let hardBreak = ReaderHighlightGeometry.sentenceContour(fragments: [
            ReaderHighlightFragment(rect: fragments[0].rect, line: 0, joinsNext: false), fragments[1]
        ], radius: 6, displayScale: 3)
        #expect(!hardBreak.contains(CGPoint(x: 60, y: 34.5)))
    }

    @Test(arguments: ReadingTheme.allCases, [false, true])
    func newBlurMirrorInheritsHighlightStateAndKeepsItsIdentity(theme: ReadingTheme, increasedContrast: Bool) throws {
        let controller = ReaderViewController(controls: Color.clear.frame(height: 132))
        controller.loadViewIfNeeded()
        let source = try #require(controller.textView.layoutManager as? ReaderHighlightLayoutManager)
        controller.textView.textStorage.setAttributedString(NSAttributedString(string: "First sentence."))
        let state = ReaderHighlightState(word: NSRange(location: 0, length: 5),
                                         sentence: NSRange(location: 0, length: 15),
                                         style: ReaderHighlightStyle(fontSize: 20, lineSpacing: 0,
                                             palette: ReaderHighlightPalette(theme: theme, increasedContrast: increasedContrast)))
        source.setHighlights(state)
        controller.configureReader(headerClearance: 96, backgroundColor: .black, reduceTransparency: false)
        let mirror = try #require(controller.textView.textStorage.layoutManagers.compactMap {
            $0 as? ReaderHighlightLayoutManager
        }.first { $0 !== source })
        #expect(mirror.highlightState == state)
        #expect(mirror.highlightTextView !== controller.textView)
        #expect(mirror.highlightTextView != nil)
        controller.configureReader(headerClearance: 96, backgroundColor: .black, reduceTransparency: false)
        #expect(controller.textView.textStorage.layoutManagers.contains { $0 === mirror })
        #expect(source.highlightState == state)
    }

    @Test func contourRoundsOuterAndInwardCornersAndLeavesHardBreaksAndBidiGaps() {
        let upper = ReaderHighlightFragment(rect: CGRect(x: 40, y: 0, width: 100, height: 20), line: 0, joinsNext: true)
        let lower = ReaderHighlightFragment(rect: CGRect(x: 0, y: 24, width: 90, height: 20), line: 1, joinsNext: false)
        let joined = ReaderHighlightGeometry.contour(fragments: [upper, lower], radius: 4, joinsLines: true)
        #expect(joined.contains(CGPoint(x: 65, y: 22)))
        #expect(!joined.contains(CGPoint(x: 5, y: 10)))
        #expect(!joined.contains(CGPoint(x: 41, y: 1))) // Exposed rounded corner.
        var curves = 0
        joined.applyWithBlock { if $0.pointee.type == .addQuadCurveToPoint { curves += 1 } }
        #expect(curves >= 8) // Includes inward steps as well as exposed corners.
        let hard = ReaderHighlightFragment(rect: upper.rect, line: 0, joinsNext: false)
        let separate = ReaderHighlightGeometry.contour(fragments: [hard, lower], radius: 4, joinsLines: true)
        #expect(!separate.contains(CGPoint(x: 65, y: 22)))
        let touching = ReaderHighlightFragment(rect: CGRect(x: 40, y: 20, width: 100, height: 20), line: 1, joinsNext: false)
        let hardTouching = ReaderHighlightGeometry.contour(fragments: [hard, touching], radius: 4, joinsLines: true)
        #expect(!hardTouching.contains(CGPoint(x: 40.5, y: 20))) // Hard breaks retain exposed corners at zero spacing.
        let bidi = ReaderHighlightFragment(rect: CGRect(x: 150, y: 24, width: 50, height: 20), line: 1, joinsNext: false)
        let disconnected = ReaderHighlightGeometry.contour(fragments: [upper, bidi], radius: 4, joinsLines: true)
        #expect(!disconnected.contains(CGPoint(x: 145, y: 22)))
        #expect(ReaderHighlightGeometry.contour(fragments: [], radius: 4, joinsLines: true).isEmpty)
    }

    @Test func joinedContourHasOneUniformTranslucentFill() throws {
        let path = ReaderHighlightGeometry.sentenceContour(fragments: [
            ReaderHighlightFragment(rect: CGRect(x: 10, y: 10, width: 80, height: 20), line: 0, joinsNext: true),
            ReaderHighlightFragment(rect: CGRect(x: 20, y: 34, width: 80, height: 20), line: 1, joinsNext: false)
        ], radius: 6, displayScale: 3)
        let pixels = try bitmap { context in
            context.addPath(path)
            context.setFillColor(UIColor.red.withAlphaComponent(0.16).cgColor)
            context.fillPath()
        }
        let body = pixels[(20 * 320 + 40) * 4 + 3]
        let connector = pixels[(32 * 320 + 40) * 4 + 3]
        let overlap = pixels[(26 * 320 + 40) * 4 + 3]
        #expect(body > 0)
        #expect(body == connector)
        #expect(body == overlap)
    }

    @Test func wrappedWordAndPartialSentenceLinesUseRealFragmentsWithoutReflow() throws {
        let fixture = makeText("Prefix text. An extraordinarilylongunbrokenword continues across several lines. Tail text.", width: 160)
        let source = fixture.storage.string as NSString
        let word = source.range(of: "extraordinarilylongunbrokenword")
        let sentence = source.range(of: "An extraordinarilylongunbrokenword continues across several lines.")
        let usedBefore = fixture.manager.usedRect(for: fixture.container)
        fixture.manager.setHighlights(ReaderHighlightState(word: word, sentence: sentence))
        try draw(fixture)
        let wordPath = try #require(fixture.manager.highlightPaths.word)
        let sentencePath = try #require(fixture.manager.highlightPaths.sentence)
        #expect(wordPath.boundingBoxOfPath.height > 30)
        let startGlyph = fixture.manager.glyphIndexForCharacter(at: sentence.location)
        let startLine = fixture.manager.lineFragmentRect(forGlyphAt: startGlyph, effectiveRange: nil)
        let prefixGlyph = fixture.manager.glyphIndexForCharacter(at: 0)
        let prefixRect = fixture.manager.boundingRect(forGlyphRange: NSRange(location: prefixGlyph, length: 1), in: fixture.container)
        #expect(!sentencePath.contains(CGPoint(x: prefixRect.midX, y: prefixRect.midY)))
        #expect(sentencePath.boundingBoxOfPath.minY >= startLine.minY - 2)
        let tailGlyphs = fixture.manager.glyphRange(forCharacterRange: source.range(of: "Tail"), actualCharacterRange: nil)
        let tailRect = fixture.manager.boundingRect(forGlyphRange: tailGlyphs, in: fixture.container)
        #expect(!sentencePath.contains(CGPoint(x: tailRect.midX, y: tailRect.midY)))
        #expect(fixture.manager.usedRect(for: fixture.container) == usedBefore)
    }

    @Test func singleWordPaddingIsModestAndTypographyAndWidthInvalidateSentenceCache() throws {
        let fixture = makeText("First words continue in this sentence across a few lines.", width: 220)
        let source = fixture.storage.string as NSString
        let sentence = NSRange(location: 0, length: source.length)
        let first = source.range(of: "First")
        fixture.manager.setHighlights(ReaderHighlightState(word: first, sentence: sentence))
        try draw(fixture)
        let firstPath = try #require(fixture.manager.highlightPaths.word)
        let firstGlyphs = fixture.manager.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        let firstRect = fixture.manager.boundingRect(forGlyphRange: firstGlyphs, in: fixture.container)
        #expect(firstPath.boundingBoxOfPath.width <= firstRect.width + 6.01)
        #expect(firstPath.boundingBoxOfPath.width > firstRect.width)
        let count = fixture.manager.sentenceGeometryBuildCount
        fixture.manager.setHighlights(ReaderHighlightState(word: source.range(of: "words"), sentence: sentence))
        try draw(fixture)
        #expect(fixture.manager.sentenceGeometryBuildCount == count)
        #expect(fixture.manager.highlightPaths.word?.boundingBoxOfPath != firstPath.boundingBoxOfPath)
        for (size, spacing, width) in [(28.0, 0.0, 220.0), (28.0, 12.0, 220.0), (28.0, 12.0, 140.0)] {
            let before = fixture.manager.sentenceGeometryBuildCount
            fixture.manager.invalidateHighlightGeometry()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            fixture.storage.addAttributes([.font: UIFont.systemFont(ofSize: size), .paragraphStyle: paragraph], range: sentence)
            fixture.container.size.width = width
            fixture.manager.setHighlights(ReaderHighlightState(word: first, sentence: sentence,
                style: ReaderHighlightStyle(fontSize: size, lineSpacing: spacing)))
            fixture.manager.ensureLayout(for: fixture.container)
            try draw(fixture)
            #expect(fixture.manager.sentenceGeometryBuildCount > before)
            #expect((fixture.manager.highlightPaths.sentence?.boundingBoxOfPath.maxX ?? 0) <= width)
        }
        fixture.manager.setHighlights(ReaderHighlightState())
        try draw(fixture)
        #expect(fixture.manager.highlightPaths.sentence == nil)
        #expect(fixture.manager.highlightPaths.word == nil)
    }

    @Test func stylesKeepRosewoodAndBoundedPaddingScale() {
        let basic = ReaderHighlightStyle(fontSize: 20, lineSpacing: 4)
        let warm = ReaderHighlightStyle(fontSize: 20, lineSpacing: 4, palette: ReaderHighlightPalette(theme: .warm))
        #expect(basic.wordColor.cgColor.alpha == 1)
        #expect(abs(basic.sentenceColor.cgColor.alpha - 0.22) < 0.000001)
        #expect(abs(warm.sentenceColor.cgColor.alpha - 0.18) < 0.000001)
        #expect(ReaderHighlightStyle(fontSize: 8, lineSpacing: 0).scale == 0.75)
        #expect(ReaderHighlightStyle(fontSize: 80, lineSpacing: 0).scale == 1.5)
    }

    @Test(arguments: [false, true])
    func palettesHaveExpectedCompositesAndReadableText(increasedContrast: Bool) throws {
        let cases: [(ReadingTheme, UInt32, Double, Double, UInt32, UInt32)] = [
            (.muted, 0xD9A6AF, 0.22, 0.28, 0x54484A, 0x5E5052),
            (.basic, 0xD4A0AA, 0.22, 0.30, 0x2F2325, 0x403033),
            (.warm, 0xB77F86, 0.18, 0.26, 0xD6C6C0, 0xD3BFBB)
        ]
        for (theme, source, normalAlpha, increasedAlpha, normalComposite, increasedComposite) in cases {
            let palette = ReaderHighlightPalette(theme: theme, increasedContrast: increasedContrast)
            let fill = try components(palette.sentenceColor)
            let expectedSource = rgb(source)
            let alpha = increasedContrast ? increasedAlpha : normalAlpha
            #expect(abs(fill[3] - alpha) < 0.000001)
            let page = try components(UIColor(theme.backgroundColor))
            let text = try components(UIColor(theme.textColor))
            let expectedComposite = rgb(increasedContrast ? increasedComposite : normalComposite)
            var composite: [Double] = []
            for channel in 0..<3 {
                #expect(abs(fill[channel] - expectedSource[channel]) < 0.000001)
                let value = alpha * fill[channel] + (1 - alpha) * page[channel]
                composite.append(value)
                #expect(abs(value - expectedComposite[channel]) <= 0.6 / 255)
            }
            #expect(contrast(text, composite) >= 4.5)
            let word = try components(palette.wordColor)
            let expectedWord = rgb(0xAF3E4D) + [1]
            for channel in 0..<4 { #expect(abs(word[channel] - expectedWord[channel]) < 0.000001) }
            #expect(contrast([1, 1, 1], word) >= 4.5)
        }
    }

    @Test func paletteOnlyChangesReuseSentenceAndWordGeometry() throws {
        let fixture = makeText("The mountain had seemed peculiar to Sunny.", width: 220)
        let source = fixture.storage.string as NSString
        var state = ReaderHighlightState(word: source.range(of: "mountain"),
                                         sentence: NSRange(location: 0, length: source.length))
        fixture.manager.setHighlights(state)
        try draw(fixture)
        let sentenceBuilds = fixture.manager.sentenceGeometryBuildCount
        let wordBuilds = fixture.manager.wordGeometryBuildCount
        let originalSentence = try #require(fixture.manager.highlightPaths.sentence)
        let originalWord = try #require(fixture.manager.highlightPaths.word)
        let used = fixture.manager.usedRect(for: fixture.container)
        for theme in ReadingTheme.allCases {
            for increasedContrast in [false, true] {
                state.style.palette = ReaderHighlightPalette(theme: theme, increasedContrast: increasedContrast)
                fixture.manager.setHighlights(state)
                try draw(fixture)
                #expect(fixture.manager.sentenceGeometryBuildCount == sentenceBuilds)
                #expect(fixture.manager.wordGeometryBuildCount == wordBuilds)
                #expect(fixture.manager.highlightPaths.sentence === originalSentence)
                #expect(fixture.manager.highlightPaths.word === originalWord)
                #expect(fixture.manager.usedRect(for: fixture.container) == used)
                #expect(fixture.manager.highlightState.style.palette == state.style.palette)
            }
        }
    }

    private func components(_ color: UIColor) throws -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let resolved = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        try #require(resolved)
        return [red, green, blue, alpha].map { Double($0) }
    }

    private func rgb(_ value: UInt32) -> [Double] {
        [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { $0 / 255 }
    }

    private func contrast(_ first: [Double], _ second: [Double]) -> Double {
        func luminance(_ color: [Double]) -> Double {
            let linear = color.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private typealias Fixture = (storage: NSTextStorage, manager: ReaderHighlightLayoutManager, container: NSTextContainer)

    private func makeText(_ text: String, width: CGFloat) -> Fixture {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.systemFont(ofSize: 20), .paragraphStyle: paragraph])
        let manager = ReaderHighlightLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: 600))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container) // Small synthetic fixtures only.
        return (storage, manager, container)
    }

    private func draw(_ fixture: Fixture) throws {
        _ = try bitmap { _ in
            fixture.manager.drawBackground(forGlyphRange: fixture.manager.glyphRange(for: fixture.container), at: .zero)
        }
    }

    private func bitmap(draw: (CGContext) -> Void) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 320 * 600 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 320, height: 600, bitsPerComponent: 8,
                bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            draw(context)
        }
        return pixels
    }
}
