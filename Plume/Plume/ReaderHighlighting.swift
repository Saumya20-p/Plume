import Foundation
import NaturalLanguage
import UIKit

nonisolated enum ReaderHighlightRanges {
    static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length > 0 &&
            range.location <= length && range.length <= length - range.location
    }

    static func firstContent(in range: NSRange, text: NSString) -> Int? {
        guard isValid(range, length: text.length) else { return nil }
        let found = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, range: range)
        return found.location == NSNotFound ? nil : found.location
    }

    /// Expansion belongs only to presentation. Playback keeps its original marker.
    static func drawingRange(_ range: NSRange?, text: NSString) -> NSRange? {
        guard let range, isValid(range, length: text.length) else { return nil }
        return text.rangeOfComposedCharacterSequences(for: range)
    }
}

/// Owns only the displayed word. The authoritative speech marker is never changed.
nonisolated struct ReaderVisualWordSelection {
    private(set) var current: NSRange?
    private var lastMarker: NSRange?

    mutating func reset() {
        current = nil
        lastMarker = nil
    }

    mutating func resolve(marker: NSRange?, text: NSString) -> NSRange? {
        guard let marker = ReaderHighlightRanges.drawingRange(marker, text: text),
              let first = ReaderHighlightRanges.firstContent(in: marker, text: text) else {
            reset()
            return nil
        }
        if marker == lastMarker { return current }
        lastMarker = marker
        // Never include whitespace, even if a producer supplies it at a marker edge.
        let whitespace = text.rangeOfCharacter(from: .whitespacesAndNewlines,
            range: NSRange(location: first, length: NSMaxRange(marker) - first))
        let end = whitespace.location == NSNotFound ? NSMaxRange(marker) : whitespace.location
        let trimmed = NSRange(location: first, length: end - first)
        let punctuationOnly = text.rangeOfCharacter(from: .punctuationCharacters.inverted, range: trimmed).location == NSNotFound
        if punctuationOnly, let current, NSIntersectionRange(trimmed, current) == trimmed {
            return current
        }

        var core = trimmed
        if punctuationOnly {
            let firstCharacter = text.rangeOfComposedCharacterSequence(at: first)
            if Self.isOpening(text.substring(with: firstCharacter)) {
                core = Self.nextWord(after: first, text: text) ?? trimmed
            } else {
                var boundary = first
                var inspected = 0
                while boundary > 0, inspected < Self.lookupLimit {
                    let previous = text.rangeOfComposedCharacterSequence(at: boundary - 1)
                    guard Self.isTrailing(text.substring(with: previous)) else { break }
                    boundary = previous.location
                    inspected += previous.length
                }
                if let preceding = Self.previousWord(before: boundary, text: text) {
                    core = preceding
                } else if Self.isStraightQuote(text.substring(with: firstCharacter)),
                          let following = Self.nextWord(after: first, text: text) {
                    core = following
                }
            }
        }
        current = Self.includingAttachedPunctuation(core, text: text)
        return current
    }

    // A cold seek onto punctuation performs a local native word lookup, never a chapter scan.
    private static let lookupLimit = 1024

    private static func previousWord(before boundary: Int, text: NSString) -> NSRange? {
        guard boundary > 0 else { return nil }
        let previous = text.rangeOfComposedCharacterSequence(at: boundary - 1)
        guard isContent(text.substring(with: previous)) else { return nil }
        var start = previous.location
        while start > 0, boundary - start < lookupLimit {
            let character = text.rangeOfComposedCharacterSequence(at: start - 1)
            let value = text.substring(with: character)
            if isWhitespace(value) || isOpening(value) { break }
            start = character.location
        }
        guard boundary - start < lookupLimit else { return nil }
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: start, length: boundary - start),
            options: [.byWords, .localized, .reverse, .substringNotRequired]) { _, range, _, stop in
                found = range
                stop.pointee = true
            }
        // Native word enumeration can omit symbol-only words such as emoji.
        return found.flatMap { NSMaxRange($0) == boundary ? $0 : nil } ?? previous
    }

    private static func nextWord(after location: Int, text: NSString) -> NSRange? {
        var start = location
        while start < text.length, start - location < lookupLimit {
            let range = text.rangeOfComposedCharacterSequence(at: start)
            let value = text.substring(with: range)
            guard isOpening(value) || isStraightQuote(value) else { break }
            start = NSMaxRange(range)
        }
        guard start < text.length else { return nil }
        let first = text.rangeOfComposedCharacterSequence(at: start)
        guard isContent(text.substring(with: first)) else { return nil }
        var end = NSMaxRange(first)
        while end < text.length, end - location < lookupLimit {
            let range = text.rangeOfComposedCharacterSequence(at: end)
            if isWhitespace(text.substring(with: range)) { break }
            end = NSMaxRange(range)
        }
        guard end - location < lookupLimit else { return nil }
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: start, length: end - start),
            options: [.byWords, .localized, .substringNotRequired]) { _, range, _, stop in
                found = range
                stop.pointee = true
            }
        return found.flatMap { $0.location == start ? $0 : nil } ?? first
    }

    private static func includingAttachedPunctuation(_ core: NSRange, text: NSString) -> NSRange {
        var start = core.location
        var end = NSMaxRange(core)
        var openingQuotes = Set<String>()
        while start > 0, core.location - start < lookupLimit {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1)
            let value = text.substring(with: previous)
            if isStraightQuote(value) {
                // An apostrophe inside a preceding word is not an opening quote.
                if previous.location > 0 {
                    let before = text.rangeOfComposedCharacterSequence(at: previous.location - 1)
                    if isContent(text.substring(with: before)) { break }
                }
                openingQuotes.insert(value)
            } else if !isOpening(value) { break }
            start = previous.location
        }
        while end < text.length, end - NSMaxRange(core) < lookupLimit {
            let next = text.rangeOfComposedCharacterSequence(at: end)
            let value = text.substring(with: next)
            guard isTrailing(value) else { break }
            if isStraightQuote(value), NSMaxRange(next) < text.length {
                let following = text.rangeOfComposedCharacterSequence(at: NSMaxRange(next))
                if isContent(text.substring(with: following)), !openingQuotes.contains(value) { break }
            }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isStraightQuote(_ value: String) -> Bool { value == "\"" || value == "'" }

    private static func isOpening(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .openPunctuation ||
            $0.properties.generalCategory == .initialPunctuation }
    }

    private static func isTrailing(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .closePunctuation, .finalPunctuation, .otherPunctuation, .dashPunctuation, .connectorPunctuation: true
            default: false
            }
        }
    }

    private static func isContent(_ value: String) -> Bool {
        !isWhitespace(value) && value.unicodeScalars.contains { !CharacterSet.punctuationCharacters.contains($0) }
    }
}

nonisolated struct ReaderSentenceRevision: Equatable, Sendable {
    let documentID: UUID
    let revision: Int
}

nonisolated struct ReaderSentenceIndex: Sendable {
    let revision: ReaderSentenceRevision
    let ranges: [NSRange]

    func sentence(containing offset: Int) -> NSRange? {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if offset < range.location { upper = middle }
            else if offset >= NSMaxRange(range) { lower = middle + 1 }
            else { return range }
        }
        return nil
    }
}

/// The tokenizer never crosses actors; only immutable UTF-16 ranges leave this worker.
actor ReaderSentenceIndexer {
    func index(text: String, revision: ReaderSentenceRevision) throws -> ReaderSentenceIndex {
        try Task.checkCancellation()
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let source = text as NSString
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { token, _ in
            guard !Task.isCancelled else { return false }
            let range = NSRange(token, in: text)
            let first = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, range: range)
            if first.location != NSNotFound {
                let last = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted,
                                                   options: .backwards, range: range)
                ranges.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            }
            return true
        }
        try Task.checkCancellation()
        return ReaderSentenceIndex(revision: revision, ranges: ranges)
    }
}

nonisolated struct ReaderSentenceSelection {
    private(set) var revision: ReaderSentenceRevision?
    private(set) var index: ReaderSentenceIndex?
    private(set) var current: NSRange?

    mutating func reset(to revision: ReaderSentenceRevision?) {
        self.revision = revision
        index = nil
        current = nil
    }

    @discardableResult
    mutating func accept(_ index: ReaderSentenceIndex) -> Bool {
        guard index.revision == revision else { return false }
        self.index = index
        return true
    }

    mutating func resolve(word: NSRange?, text: NSString) -> NSRange? {
        guard let word, let offset = ReaderHighlightRanges.firstContent(in: word, text: text) else {
            current = nil
            return nil
        }
        if let current, NSLocationInRange(offset, current) { return current }
        current = index?.sentence(containing: offset)
        return current
    }
}

/// Fixed sRGB paints selected by the reader theme and the current accessibility contrast.
/// The word remains the primary, opaque rosewood emphasis in every palette.
struct ReaderHighlightPalette: Equatable {
    static let basic = ReaderHighlightPalette(theme: .basic)
    let sentenceColor: UIColor
    let wordColor = UIColor(red: 175 / 255, green: 62 / 255, blue: 77 / 255, alpha: 1)

    init(theme: ReadingTheme, increasedContrast: Bool = false) {
        switch theme {
        case .muted:
            sentenceColor = UIColor(red: 217 / 255, green: 166 / 255, blue: 175 / 255,
                                    alpha: increasedContrast ? 0.28 : 0.22)
        case .basic:
            sentenceColor = UIColor(red: 212 / 255, green: 160 / 255, blue: 170 / 255,
                                    alpha: increasedContrast ? 0.30 : 0.22)
        case .warm:
            sentenceColor = UIColor(red: 183 / 255, green: 127 / 255, blue: 134 / 255,
                                    alpha: increasedContrast ? 0.26 : 0.18)
        }
    }
}

struct ReaderHighlightStyle: Equatable {
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    var palette: ReaderHighlightPalette = .basic

    var scale: CGFloat { min(1.5, max(0.75, fontSize / 20)) }
    var wordColor: UIColor { palette.wordColor }
    var sentenceColor: UIColor { palette.sentenceColor }
}

struct ReaderHighlightState: Equatable {
    var word: NSRange?
    var sentence: NSRange?
    var style = ReaderHighlightStyle(fontSize: 20, lineSpacing: 0)
}

/// A fragment is one enclosing rectangle, not a bounding box across bidi runs.
struct ReaderHighlightFragment {
    var rect: CGRect
    let line: Int
    let joinsNext: Bool
    var unpaddedRect: CGRect? = nil
    /// Limits for additional horizontal background only. Nil means no expansion.
    var horizontalExpansionBounds: ClosedRange<CGFloat>? = nil
}

enum ReaderHighlightGeometry {
    static func contour(fragments: [ReaderHighlightFragment], radius: CGFloat, joinsLines: Bool) -> CGPath {
        makeContour(fragments: fragments, radius: radius, joinsLines: joinsLines, sentencePixel: nil)
    }

    static func sentenceEdgeTolerance(fontSize: CGFloat) -> CGFloat {
        4 * min(1.5, max(0.75, fontSize / 20))
    }

    static func sentenceContour(fragments: [ReaderHighlightFragment], radius: CGFloat, displayScale: CGFloat,
                                fontSize: CGFloat = 20) -> CGPath {
        let pixel = 1 / max(1, displayScale)
        let aligned = alignedSentenceFragments(fragments, tolerance: sentenceEdgeTolerance(fontSize: fontSize))
        return makeContour(fragments: aligned, radius: radius, joinsLines: true, sentencePixel: pixel)
    }

    static func alignedSentenceFragments(_ fragments: [ReaderHighlightFragment], tolerance: CGFloat) -> [ReaderHighlightFragment] {
        var aligned = fragments
        let rows = Dictionary(grouping: fragments.indices, by: { fragments[$0].line })
        var next: [Int: Int] = [:]
        var previous: [Int: Int] = [:]
        // Only match unambiguous, overlapping runs on consecutive wrapped lines.
        // Use original geometry so expansion cannot create a new bidi connection.
        for line in rows.keys.sorted() {
            guard let upper = rows[line], let lower = rows[line + 1] else { continue }
            var matches: [Int: [Int]] = [:]
            var reverseMatches: [Int: [Int]] = [:]
            for first in upper where fragments[first].joinsNext {
                for second in lower {
                    let a = fragments[first].unpaddedRect ?? fragments[first].rect
                    let b = fragments[second].unpaddedRect ?? fragments[second].rect
                    guard b.minY > a.minY, min(a.maxX, b.maxX) > max(a.minX, b.minX) else { continue }
                    matches[first, default: []].append(second)
                    reverseMatches[second, default: []].append(first)
                }
            }
            for first in upper {
                guard let candidates = matches[first], candidates.count == 1,
                      let second = candidates.first, reverseMatches[second]?.count == 1 else { continue }
                next[first] = second
                previous[second] = first
            }
        }

        func edge(_ index: Int, left: Bool) -> CGFloat {
            left ? fragments[index].rect.minX : fragments[index].rect.maxX
        }
        func canReach(_ index: Int, target: CGFloat, left: Bool) -> Bool {
            if target == edge(index, left: left) { return true } // No new background.
            return fragments[index].horizontalExpansionBounds?.contains(target) == true
        }
        func apply(_ group: [Int], target: CGFloat, left: Bool) {
            for index in group {
                let rect = aligned[index].rect
                let minX = left ? target : rect.minX
                let maxX = left ? rect.maxX : target
                aligned[index].rect = CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height)
            }
        }
        for start in fragments.indices where previous[start] == nil {
            var chain = [start]
            while let successor = next[chain[chain.count - 1]] { chain.append(successor) }
            for left in [true, false] {
                var group: [Int] = []
                var minimum: CGFloat = 0
                var maximum: CGFloat = 0
                for index in chain {
                    let value = edge(index, left: left)
                    if group.isEmpty { group = [index]; minimum = value; maximum = value; continue }
                    let low = min(minimum, value), high = max(maximum, value)
                    let target = left ? low : high
                    if high - low <= tolerance, canReach(index, target: target, left: left),
                       group.allSatisfy({ canReach($0, target: target, left: left) }) {
                        group.append(index)
                        minimum = low
                        maximum = high
                    } else {
                        apply(group, target: left ? minimum : maximum, left: left)
                        group = [index]
                        minimum = value
                        maximum = value
                    }
                }
                apply(group, target: left ? minimum : maximum, left: left)
            }
        }
        return aligned
    }

    /// The nearest glyph/run on either side bounds free background space.
    /// Touching blockers can prohibit one edge without disabling the other edge.
    static func sentenceExpansionBounds(for rect: CGRect, containerBounds: CGRect,
                                         obstacles: [CGRect], clearance: CGFloat) -> ClosedRange<CGFloat>? {
        var left = containerBounds.minX
        var right = containerBounds.maxX
        for obstacle in obstacles where obstacle.maxY > rect.minY && obstacle.minY < rect.maxY {
            if obstacle.maxX <= rect.minX { left = max(left, obstacle.maxX + clearance) }
            else if obstacle.minX >= rect.maxX { right = min(right, obstacle.minX - clearance) }
            else { return nil } // Cannot establish a safe horizontal corridor.
        }
        return left <= right ? left...right : nil
    }

    private static func makeContour(fragments: [ReaderHighlightFragment], radius: CGFloat,
                                    joinsLines: Bool, sentencePixel: CGFloat?) -> CGPath {
        let rows = Dictionary(grouping: fragments, by: \.line)
        var components: [CGMutablePath] = []
        var previousLine: Int?
        var previousRow: [ReaderHighlightFragment] = []
        for line in rows.keys.sorted() {
            guard let row = rows[line] else { continue }
            let connects = joinsLines && previousLine.map { $0 + 1 == line } == true &&
                previousRow.contains { $0.joinsNext }
            if !connects { components.append(CGMutablePath()) }
            guard let component = components.last else { continue }
            for fragment in row { component.addRect(fragment.rect) }
            if connects {
                for upper in previousRow where upper.joinsNext {
                    for lower in row {
                        let upperRun = upper.unpaddedRect ?? upper.rect
                        let lowerRun = lower.unpaddedRect ?? lower.rect
                        guard min(upperRun.maxX, lowerRun.maxX) > max(upperRun.minX, lowerRun.minX) else { continue }
                        let left = max(upper.rect.minX, lower.rect.minX)
                        let right = min(upper.rect.maxX, lower.rect.maxX)
                        guard right > left, lower.rect.minY > upper.rect.minY else { continue }
                        // Only overlapping adjacent runs connect; no horizontal bounding-box bridges.
                        component.addRect(CGRect(x: left, y: upper.rect.midY, width: right - left,
                                                 height: lower.rect.midY - upper.rect.midY))
                    }
                }
            }
            previousLine = line
            previousRow = row
        }
        // Normalize first, then round the exposed contour (including inward steps).
        // A single fill prevents darker seams where fragments and connectors overlap.
        let rounded = CGMutablePath()
        var vertices: [CGPoint] = []
        func appendContour() {
            guard !vertices.isEmpty else { return }
            if let pixel = sentencePixel {
                var distinct: [CGPoint] = []
                for point in vertices {
                    if let last = distinct.last, hypot(point.x - last.x, point.y - last.y) <= pixel / 16 { continue }
                    distinct.append(point)
                }
                if let first = distinct.first, let last = distinct.last,
                   hypot(first.x - last.x, first.y - last.y) <= pixel / 16 { distinct.removeLast() }
                vertices = distinct
            } else if vertices.last == vertices.first { vertices.removeLast() }
            // Remove collinear vertices so tiny redundant edges do not limit a corner.
            var simplified: [CGPoint] = []
            for index in vertices.indices {
                let previous = vertices[(index + vertices.count - 1) % vertices.count]
                let point = vertices[index]
                let next = vertices[(index + 1) % vertices.count]
                let cross = (point.x - previous.x) * (next.y - point.y) -
                    (point.y - previous.y) * (next.x - point.x)
                let tolerance = sentencePixel.map { pixel in
                    pixel / 16 * max(hypot(point.x - previous.x, point.y - previous.y),
                                     hypot(next.x - point.x, next.y - point.y))
                } ?? 0.0001
                if abs(cross) > tolerance { simplified.append(point) }
            }
            guard simplified.count >= 3 else { vertices.removeAll(); return }
            for index in simplified.indices {
                let previous = simplified[(index + simplified.count - 1) % simplified.count]
                let point = simplified[index]
                let next = simplified[(index + 1) % simplified.count]
                let before = hypot(previous.x - point.x, previous.y - point.y)
                let after = hypot(next.x - point.x, next.y - point.y)
                let corner = min(radius, before / 2, after / 2)
                // Independent tangent lengths let a short step stay smooth without
                // shrinking both sides of its corner to the shortest edge.
                let incoming = sentencePixel == nil ? corner : min(radius, before / 2)
                let outgoing = sentencePixel == nil ? corner : min(radius, after / 2)
                let entry = CGPoint(x: point.x + (previous.x - point.x) * incoming / before,
                                    y: point.y + (previous.y - point.y) * incoming / before)
                let exit = CGPoint(x: point.x + (next.x - point.x) * outgoing / after,
                                   y: point.y + (next.y - point.y) * outgoing / after)
                if index == 0 { rounded.move(to: entry) } else { rounded.addLine(to: entry) }
                rounded.addQuadCurve(to: exit, control: point)
            }
            rounded.closeSubpath()
            vertices.removeAll()
        }
        // Keep hard-break components separate even when zero line spacing makes
        // their rectangles touch. Wrapped words also retain one rounded shape per line.
        for component in components {
            let normalized = component.normalized(using: .winding)
            // Native boolean operations need not preserve the input element types.
            // Flatten the sentence union before extracting vertices; never drop curve edges.
            let outline = sentencePixel.map { normalized.flattened(threshold: $0 / 16) } ?? normalized
            outline.applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint:
                    appendContour()
                    vertices = [element.pointee.points[0]]
                case .addLineToPoint: vertices.append(element.pointee.points[0])
                case .closeSubpath: appendContour()
                // Sentence outlines were flattened above. Keep the existing word path intact.
                case .addQuadCurveToPoint, .addCurveToPoint: break
                @unknown default: break
                }
            }
            appendContour()
        }
        return rounded
    }
}

/// Display-only TextKit 1 highlights shared by the sharp reader and its blur mirror.
final class ReaderHighlightLayoutManager: NSLayoutManager {
    weak var highlightTextView: UITextView?
    private(set) var highlightState = ReaderHighlightState()
    private var geometryRevision = 0
    private struct Line: Equatable {
        let glyphs: NSRange
        let characters: NSRange
        let bounds: CGRect
        let used: CGRect
        let hardBreakAfter: Bool
    }
    private struct HighlightGeometryKey: Equatable {
        let range: NSRange
        let lines: [Line]
        let containerSize: CGSize
        let revision: Int
        let displayScale: CGFloat
    }
    private var sentenceKey: HighlightGeometryKey?
    private var wordKey: HighlightGeometryKey?
    private var sentencePath: CGPath?
    private var wordPath: CGPath?
    #if DEBUG
    private(set) var sentenceGeometryBuildCount = 0
    private(set) var wordGeometryBuildCount = 0
    var highlightPaths: (sentence: CGPath?, word: CGPath?) { (sentencePath, wordPath) }
    #endif

    func setHighlights(_ state: ReaderHighlightState) {
        guard state != highlightState else { return }
        let old = highlightState
        let metricsChanged = old.style.fontSize != state.style.fontSize || old.style.lineSpacing != state.style.lineSpacing
        let sentenceGeometryChanged = old.sentence != state.sentence || metricsChanged
        let sentenceNeedsDisplay = sentenceGeometryChanged || old.style.palette != state.style.palette
        // Dirty the old padded contour before dropping it.
        invalidatePaths(includeSentence: sentenceNeedsDisplay)
        highlightState = state
        if sentenceGeometryChanged {
            sentenceKey = nil
            sentencePath = nil
        }
        if old.word != state.word || metricsChanged {
            wordKey = nil
            wordPath = nil
        }
        invalidateVisibleRanges([old.word, state.word, sentenceNeedsDisplay ? old.sentence : nil,
                                 sentenceNeedsDisplay ? state.sentence : nil])
    }

    func invalidateHighlightGeometry() {
        invalidatePaths()
        geometryRevision &+= 1
        sentenceKey = nil
        wordKey = nil
        sentencePath = nil
        wordPath = nil
    }

    override func textContainerChangedGeometry(_ container: NSTextContainer) {
        invalidateHighlightGeometry()
        super.textContainerChangedGeometry(container)
    }

    private func invalidatePaths(includeSentence: Bool = true) {
        guard let view = highlightTextView else { return }
        for path in [includeSentence ? sentencePath : nil, wordPath].compactMap({ $0 }) {
            view.setNeedsDisplay(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
                .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top))
        }
    }

    private func viewport(in container: NSTextContainer) -> CGRect? {
        guard let view = highlightTextView else { return nil }
        // Include already-laid neighboring lines, without asking TextKit for more layout.
        let margin = highlightState.style.fontSize * 3 + highlightState.style.lineSpacing
        return view.bounds.offsetBy(dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
            .insetBy(dx: 0, dy: -margin)
    }

    private func invalidateVisibleRanges(_ ranges: [NSRange?]) {
        guard let container = textContainers.first, let viewport = viewport(in: container) else { return }
        let glyphs = glyphRange(forBoundingRectWithoutAdditionalLayout: viewport, in: container)
        guard glyphs.length > 0 else { return }
        let visibleCharacters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for range in ranges.compactMap({ $0 }) {
            let visible = NSIntersectionRange(range, visibleCharacters)
            guard visible.length > 0 else { continue }
            let affected = glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            // Redraw whole neighboring lines as padding/joins extend beyond glyph bounds.
            let firstRect = lineFragmentRect(forGlyphAt: affected.location, effectiveRange: nil, withoutAdditionalLayout: true)
            let lastRect = lineFragmentRect(forGlyphAt: NSMaxRange(affected) - 1, effectiveRange: nil, withoutAdditionalLayout: true)
            let dirty = firstRect.union(lastRect).insetBy(dx: 0, dy: -highlightState.style.fontSize * 2)
            let neighbors = glyphRange(forBoundingRectWithoutAdditionalLayout: dirty, in: container)
            if neighbors.length > 0 { invalidateDisplay(forGlyphRange: neighbors) }
        }
    }

    private func visibleLines(glyphs: NSRange, container: NSTextContainer, source: NSString) -> [Line] {
        let requested = viewport(in: container).map {
            glyphRange(forBoundingRectWithoutAdditionalLayout: $0, in: container)
        } ?? glyphs
        guard requested.length > 0 else { return [] }
        var lines: [Line] = []
        var position = requested.location
        while position < NSMaxRange(requested) {
            var range = NSRange()
            let bounds = lineFragmentRect(forGlyphAt: position, effectiveRange: &range, withoutAdditionalLayout: true)
            guard !bounds.isEmpty, range.length > 0, NSMaxRange(range) > position,
                  textContainer(forGlyphAt: position, effectiveRange: nil, withoutAdditionalLayout: true) === container else { break }
            let used = lineFragmentUsedRect(forGlyphAt: position, effectiveRange: nil, withoutAdditionalLayout: true)
            let characters = characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let end = NSMaxRange(characters)
            let hardBreak = end > 0 && end <= source.length && source.rangeOfCharacter(
                from: .newlines, range: NSRange(location: end - 1, length: 1)).location != NSNotFound
            lines.append(Line(glyphs: range, characters: characters, bounds: bounds, used: used, hardBreakAfter: hardBreak))
            position = NSMaxRange(range)
        }
        return lines
    }

    private func fragments(for range: NSRange, lines: [Line], container: NSTextContainer,
                           word: Bool) -> [ReaderHighlightFragment] {
        let scale = highlightState.style.scale
        let horizontal = (word ? 3.0 : 2.0) * scale
        let vertical = (word ? 1.5 : 1.0) * scale
        let pixel = 1 / max(1, highlightTextView?.traitCollection.displayScale ?? 2)
        var fragments: [ReaderHighlightFragment] = []
        for (index, line) in lines.enumerated() {
            // Intersect characters before converting to glyphs: never lay out a long sentence.
            let characters = NSIntersectionRange(range, line.characters)
            guard characters.length > 0 else { continue }
            var actualCharacters = NSRange()
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: characters, actualCharacterRange: &actualCharacters), line.glyphs)
            guard glyphs.length > 0 else { continue }
            var rects: [CGRect] = []
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                     in: container) { rect, _ in
                if !rect.isEmpty { rects.append(rect) }
            }
            var outsideRects: [CGRect] = []
            let canMeasureExpansion = !word && actualCharacters.length > 0 &&
                NSIntersectionRange(actualCharacters, range) == actualCharacters
            if canMeasureExpansion {
                let outside = [
                    NSRange(location: line.glyphs.location, length: glyphs.location - line.glyphs.location),
                    NSRange(location: NSMaxRange(glyphs), length: NSMaxRange(line.glyphs) - NSMaxRange(glyphs))
                ]
                for otherGlyphs in outside where otherGlyphs.length > 0 {
                    enumerateEnclosingRects(forGlyphRange: otherGlyphs,
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                        if !rect.isEmpty { outsideRects.append(rect) }
                    }
                    // Include actual ink overhangs as well as the enclosing text rectangles.
                    let ink = boundingRect(forGlyphRange: otherGlyphs, in: container)
                    if !ink.isEmpty { outsideRects.append(ink) }
                }
            }
            for rect in rects {
                var left = min(horizontal, max(0, rect.minX), max(0, rect.minX - line.bounds.minX))
                var right = min(horizontal, max(0, container.size.width - rect.maxX), max(0, line.bounds.maxX - rect.maxX))
                for other in rects where other != rect {
                    if other.maxX <= rect.minX { left = min(left, max(0, (rect.minX - other.maxX) / 2 - 0.25)) }
                    if other.minX >= rect.maxX { right = min(right, max(0, (other.minX - rect.maxX) / 2 - 0.25)) }
                }
                let topClearance = index > 0 ? max(0, (rect.minY - lines[index - 1].used.maxY) / 2 - 0.25) : max(0, rect.minY)
                let bottomClearance = index + 1 < lines.count ? max(0, (lines[index + 1].used.minY - rect.maxY) / 2 - 0.25) : vertical
                let top = min(vertical, topClearance)
                let bottom = min(vertical, bottomClearance, max(0, container.size.height - rect.maxY))
                let padded = CGRect(x: rect.minX - left, y: rect.minY - top,
                                    width: rect.width + left + right, height: rect.height + top + bottom)
                var expansionBounds: ClosedRange<CGFloat>?
                if canMeasureExpansion {
                    let minimum = max(0, line.bounds.minX)
                    let maximum = min(container.size.width, line.bounds.maxX)
                    if minimum <= maximum {
                        let bounds = CGRect(x: minimum, y: line.bounds.minY,
                                            width: maximum - minimum, height: line.bounds.height)
                        expansionBounds = ReaderHighlightGeometry.sentenceExpansionBounds(
                            for: rect, containerBounds: bounds,
                            obstacles: outsideRects + rects.filter { $0 != rect }, clearance: pixel)
                    }
                }
                fragments.append(ReaderHighlightFragment(rect: padded, line: index, joinsNext: !line.hardBreakAfter,
                                                         unpaddedRect: rect, horizontalExpansionBounds: expansionBounds))
            }
        }
        return fragments
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard glyphsToShow.length > 0, let storage = textStorage,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil, withoutAdditionalLayout: true),
              let context = UIGraphicsGetCurrentContext() else { return }
        let source = storage.string as NSString
        let lines = visibleLines(glyphs: glyphsToShow, container: container, source: source)
        let style = highlightState.style
        let displayScale = highlightTextView?.traitCollection.displayScale ?? 2
        if let sentence = highlightState.sentence, ReaderHighlightRanges.isValid(sentence, length: source.length) {
            let key = HighlightGeometryKey(range: sentence, lines: lines, containerSize: container.size,
                                           revision: geometryRevision, displayScale: displayScale)
            if sentenceKey != key {
                sentenceKey = key
                sentencePath = ReaderHighlightGeometry.sentenceContour(
                    fragments: fragments(for: sentence, lines: lines, container: container, word: false),
                    radius: 6 * style.scale, displayScale: displayScale, fontSize: style.fontSize)
                #if DEBUG
                sentenceGeometryBuildCount += 1
                #endif
            }
        } else { sentenceKey = nil; sentencePath = nil }
        if let word = highlightState.word, ReaderHighlightRanges.isValid(word, length: source.length) {
            let key = HighlightGeometryKey(range: word, lines: lines, containerSize: container.size,
                                           revision: geometryRevision, displayScale: displayScale)
            if wordKey != key {
                wordKey = key
                wordPath = ReaderHighlightGeometry.contour(fragments: fragments(for: word, lines: lines, container: container, word: true),
                                                           radius: 5 * style.scale, joinsLines: false)
                #if DEBUG
                wordGeometryBuildCount += 1
                #endif
            }
        } else { wordKey = nil; wordPath = nil }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        if let sentencePath {
            context.addPath(sentencePath)
            context.setFillColor(style.sentenceColor.cgColor)
            context.fillPath()
        }
        if let wordPath {
            context.addPath(wordPath)
            context.setFillColor(style.wordColor.cgColor)
            context.fillPath()
        }
    }
}
