import SwiftUI
import UIKit

/// Keeps the reading surface, progressive foreground blur, and dock in one hierarchy.
struct PlayableTextView<Controls: View>: UIViewControllerRepresentable {
    let text: String
    let documentID: UUID
    let currentWord: WordTimestamp?
    let appearanceManager: AppearanceManager
    let typographyRevision: Int
    let readerFont: ReaderFont
    let fontSize: Double
    let isBold: Bool
    let systemBold: Bool
    let contentSizeCategory: UIContentSizeCategory
    let lineSpacing: Double
    let textColor: UIColor
    let backgroundColor: UIColor
    let headerClearance: CGFloat
    let showsReturnPill: Bool
    let reduceTransparency: Bool
    let isWarmTheme: Bool
    var highlightPalette: ReaderHighlightPalette = .basic
    let canAutoResume: Bool
    let reduceMotion: Bool
    let isSeeking: Bool
    let controlsHidden: Bool
    let onSurfaceInteraction: () -> Bool
    let onFollowStatusChanged: (ReaderFollowStatus) -> Void
    let returnRequest: Int
    let interactionRequest: Int
    let onBrowsingChanged: (Bool) -> Void
    let onWordTapped: (TimeInterval?, Int) -> Void
    let controls: Controls

    func makeUIViewController(context: Context) -> ReaderViewController<Controls> {
        let controller = ReaderViewController(controls: controls)
        controller.loadViewIfNeeded()
        controller.textView.accessibilityIdentifier = "reader.text"
        controller.textView.delegate = context.coordinator
        context.coordinator.textView = controller.textView
        appearanceManager.readerAttached(context.coordinator.readerID)
        controller.onTypographySettled = { [weak coordinator = context.coordinator] revision in
            guard let coordinator else { return }
            coordinator.parent.appearanceManager.readerAppliedTypography(revision, reader: coordinator.readerID)
        }
        context.coordinator.onReaderScroll = { [weak controller] in
            controller?.synchronizeBlurredTextOffset()
        }
        controller.onReaderLayout = { [weak coordinator = context.coordinator] geometryChanged in
            guard let coordinator, !coordinator.isUpdatingReader else { return }
            if geometryChanged { coordinator.typographyAnchor = nil }
            guard !coordinator.follow.isBrowsing,
                  coordinator.parent.canAutoResume || coordinator.lastScrolledWordCharIndex == -1 else { return }
            coordinator.scrollToCurrentWord(force: geometryChanged)
        }
        context.coordinator.readingBand = { [weak controller] in controller?.readingBand }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        controller.textView.addGestureRecognizer(tap)
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController<Controls>, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        coordinator.isUpdatingReader = true
        defer {
            coordinator.isUpdatingReader = false
            coordinator.reportFollowStatus()
        }
        controller.controlsHost.rootView = controls
        // Word captions have fixed dimensions. Only structural/typographic changes
        // need a new UIKit hit region, rather than every playback highlight.
        if previous.showsReturnPill != showsReturnPill ||
            previous.contentSizeCategory != contentSizeCategory || previous.systemBold != systemBold {
            controller.invalidateControlsLayout()
        }
        controller.overrideUserInterfaceStyle = isWarmTheme ? .light : .dark
        controller.configureReader(
            headerClearance: headerClearance,
            backgroundColor: backgroundColor,
            reduceTransparency: reduceTransparency
        )
        let textView = controller.textView
        let font = makeFont()
        controller.setControlsHidden(controlsHidden, reduceMotion: reduceMotion)
        let textChanged = coordinator.lastText != text || previous.documentID != documentID
        let fontChanged = coordinator.lastFont != font
        let spacingChanged = coordinator.lastLineSpacing != lineSpacing
        let colorsChanged = coordinator.lastTextColor != textColor || coordinator.lastWarmTheme != isWarmTheme
        let paletteChanged = previous.highlightPalette != highlightPalette
        let wordChanged = textChanged || coordinator.lastCurrentWord != currentWord
        let reflowed = !textChanged && (fontChanged || spacingChanged)
        let anchor = reflowed ? coordinator.captureReadingAnchor() : nil

        if textChanged {
            coordinator.cancelResume()
            coordinator.startSentenceIndex(text: text, documentID: documentID)
            coordinator.follow = ReaderFollowContract()
            coordinator.typographyAnchor = nil
            coordinator.lastScrolledWordCharIndex = -1
            coordinator.hasDestination = false
        }
        let storage = textView.textStorage
        if textChanged || fontChanged || spacingChanged { controller.invalidateHighlightGeometry() }
        let fullRange = NSRange(location: 0, length: storage.length)
        // A style change never replaces the characters. Edit formatting and
        // highlights together so both layout managers see one consistent update.
        storage.beginEditing()
        if textChanged {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = CGFloat(lineSpacing)
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph
            ]))
            coordinator.lastWordRange = nil
            coordinator.lastVisualWordRange = nil
        } else if storage.length > 0 {
            if fontChanged { storage.addAttribute(.font, value: font, range: fullRange) }
            if spacingChanged {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = CGFloat(lineSpacing)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            }
            if colorsChanged { storage.addAttribute(.foregroundColor, value: textColor, range: fullRange) }
        }
        coordinator.lastText = text
        coordinator.lastFont = font
        coordinator.lastLineSpacing = lineSpacing
        coordinator.lastTextColor = textColor
        coordinator.lastWarmTheme = isWarmTheme

        if isSeeking {
            coordinator.hasDestination = false
            coordinator.lastScrolledWordCharIndex = -1
        }
        let allowed = canAutoResume && !UIAccessibility.isVoiceOverRunning
        coordinator.follow.setAutoResumeAllowed(allowed, now: ProcessInfo.processInfo.systemUptime)
        if coordinator.lastInteractionRequest != interactionRequest {
            coordinator.lastInteractionRequest = interactionRequest
            if coordinator.follow.isBrowsing && !coordinator.follow.isInteracting {
                coordinator.follow.endInteraction(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        coordinator.scheduleResume()

        var newWordRange = coordinator.lastWordRange
        if wordChanged {
            newWordRange = nil
            if let word = currentWord, let location = word.rangeLocation, let length = word.rangeLength,
               coordinator.isValidTextRange(NSRange(location: location, length: length)) {
                let range = NSRange(location: location, length: length)
                newWordRange = range
            }
            coordinator.lastCurrentWord = currentWord
        }
        let visualWordRange = coordinator.resolveVisualWord(newWordRange)
        if textChanged || colorsChanged || coordinator.lastVisualWordRange != visualWordRange {
            if let range = coordinator.lastVisualWordRange, coordinator.isValidTextRange(range) {
                storage.addAttribute(.foregroundColor, value: textColor, range: range)
            }
            if let range = visualWordRange, coordinator.isValidTextRange(range) {
                storage.addAttribute(.foregroundColor, value: UIColor.white, range: range)
            }
        }
        coordinator.lastWordRange = newWordRange
        coordinator.lastVisualWordRange = visualWordRange
        storage.endEditing()
        coordinator.updateHighlights()
        if let anchor {
            let trace = StabilityTrace.begin("ReaderRestoration", revision: typographyRevision)
            coordinator.restoreReadingAnchor(anchor)
            StabilityTrace.end("ReaderRestoration", trace)
        }
        if coordinator.lastSubmittedTypographyRevision != typographyRevision || textChanged || reflowed {
            coordinator.lastSubmittedTypographyRevision = typographyRevision
            controller.requestTextLayout(revision: typographyRevision)
        }
        coordinator.onReaderScroll?()
        coordinator.isUpdatingReader = false

        if coordinator.lastReturnRequest != returnRequest {
            coordinator.lastReturnRequest = returnRequest
            coordinator.returnToCurrentWord()
        } else if (textChanged || (!reflowed && !colorsChanged && (!paletteChanged || wordChanged))) &&
                    !coordinator.follow.isBrowsing && (allowed || textChanged || previous.canAutoResume) {
            // A final marker and the stopped state can arrive together. Finish
            // following that marker, then leave the resulting offset in place.
            coordinator.scrollToCurrentWord(force: textChanged)
        }
    }

    static func dismantleUIViewController(_ controller: ReaderViewController<Controls>, coordinator: Coordinator) {
        coordinator.cancelResume()
        coordinator.cancelSentenceIndex()
        coordinator.parent.appearanceManager.readerDetached(coordinator.readerID)
        controller.onTypographySettled = nil
        controller.textView.delegate = nil
        controller.onReaderLayout = nil
        coordinator.textView = nil
        coordinator.onReaderScroll = nil
        coordinator.readingBand = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeFont() -> UIFont {
        let size = CGFloat(fontSize)
        let bold = isBold || systemBold
        let base: UIFont
        if readerFont == .georgia {
            base = UIFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) ?? .systemFont(ofSize: size)
        } else {
            let system = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            let design: UIFontDescriptor.SystemDesign
            switch readerFont {
            case .georgia, .system: design = .default
            case .serif: design = .serif
            case .rounded: design = .rounded
            case .monospaced: design = .monospaced
            }
            base = UIFont(descriptor: system.fontDescriptor.withDesign(design) ?? system.fontDescriptor, size: size)
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let readerID = UUID()
        var lastSubmittedTypographyRevision: Int?
        var parent: PlayableTextView
        weak var textView: UITextView?
        var onReaderScroll: (() -> Void)?
        var readingBand: (() -> ClosedRange<CGFloat>?)?
        var follow = ReaderFollowContract()
        var resumeTask: Task<Void, Never>?
        var scheduledRevision: Int?
        var lastReturnRequest: Int
        var lastInteractionRequest: Int
        var lastScrolledWordCharIndex = -1
        var lastText: String?
        var lastFont: UIFont?
        var lastLineSpacing: Double?
        var lastTextColor: UIColor?
        var lastWarmTheme: Bool?
        var lastWordRange: NSRange?
        var lastVisualWordRange: NSRange?
        private var visualWordSelection = ReaderVisualWordSelection()
        private var sentenceSelection = ReaderSentenceSelection()
        private let sentenceIndexer = ReaderSentenceIndexer()
        private var sentenceIndexTask: Task<Void, Never>?
        private var textRevision = 0
        private var highlightText: NSString = ""
        var lastCurrentWord: WordTimestamp?
        var isUpdatingReader = false
        var hasDestination = false
        private var lastReportedStatus: ReaderFollowStatus?
        private var reportRevision = 0

        func reportFollowStatus() {
            let status = ReaderFollowStatus(documentID: parent.documentID, isBrowsing: follow.isBrowsing,
                                            isInteracting: follow.isInteracting, hasDestination: hasDestination)
            guard status != lastReportedStatus else { return }
            lastReportedStatus = status
            reportRevision &+= 1
            let revision = reportRevision
            // A delegate/layout callback can occur during a representable update.
            // Coalesce and publish only the latest snapshot outside that transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textView != nil, self.reportRevision == revision,
                      self.parent.documentID == status.documentID else { return }
                self.parent.onFollowStatusChanged(status)
            }
        }

        var typographyAnchor: ReadingAnchor?

        struct ReadingAnchor {
            let characterIndex: Int
            let viewportY: CGFloat
        }

        init(_ parent: PlayableTextView) {
            self.parent = parent
            lastReturnRequest = parent.returnRequest
            lastInteractionRequest = parent.interactionRequest
        }

        deinit {
            resumeTask?.cancel()
            sentenceIndexTask?.cancel()
        }

        func startSentenceIndex(text: String, documentID: UUID) {
            cancelSentenceIndex()
            textRevision &+= 1
            let revision = ReaderSentenceRevision(documentID: documentID, revision: textRevision)
            sentenceSelection.reset(to: revision)
            highlightText = text as NSString
            visualWordSelection.reset()
            let indexer = sentenceIndexer
            // Independent of follow/resume: a browsing or paused reader still gets its sentence.
            sentenceIndexTask = Task { @MainActor [weak self] in
                do {
                    let index = try await indexer.index(text: text, revision: revision)
                    guard !Task.isCancelled, let self, self.textView != nil,
                          self.parent.documentID == revision.documentID,
                          self.sentenceSelection.accept(index) else { return }
                    self.sentenceIndexTask = nil
                    // Playback may have advanced during indexing. Resolve the latest validated marker.
                    self.updateHighlights()
                } catch is CancellationError {
                    return
                } catch {
                    // A missing presentation index leaves the immediate word highlight available.
                    return
                }
            }
        }

        func cancelSentenceIndex() {
            sentenceIndexTask?.cancel()
            sentenceIndexTask = nil
            sentenceSelection.reset(to: nil)
        }

        func updateHighlights() {
            guard let textView else { return }
            let sentence = sentenceSelection.resolve(word: lastWordRange, text: highlightText)
            let state = ReaderHighlightState(
                word: lastVisualWordRange,
                sentence: ReaderHighlightRanges.drawingRange(sentence, text: highlightText),
                style: ReaderHighlightStyle(fontSize: lastFont?.pointSize ?? CGFloat(parent.fontSize),
                                            lineSpacing: CGFloat(parent.lineSpacing), palette: parent.highlightPalette))
            for manager in textView.textStorage.layoutManagers {
                (manager as? ReaderHighlightLayoutManager)?.setHighlights(state)
            }
        }

        func resolveVisualWord(_ marker: NSRange?) -> NSRange? {
            visualWordSelection.resolve(marker: marker, text: highlightText)
        }

        func isValidTextRange(_ range: NSRange) -> Bool {
            guard let textView else { return false }
            return ReaderHighlightRanges.isValid(range, length: textView.textStorage.length)
        }

        func captureReadingAnchor() -> ReadingAnchor? {
            // Keep the same character through successive previews. Recapturing
            // a newly wrapped line each frame would accumulate position drift.
            if let typographyAnchor { return typographyAnchor }
            guard let textView, textView.bounds.height > 0, textView.textStorage.length > 0,
                  let band = readingBand?() else { return nil }
            // Stop a pending follow animation before measuring the visible line.
            textView.setContentOffset(textView.contentOffset, animated: false)
            let point = CGPoint(x: 0, y: max(0, textView.contentOffset.y + band.lowerBound - textView.textContainerInset.top))
            let manager = textView.layoutManager
            let character = manager.characterIndex(for: point, in: textView.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            guard character < textView.textStorage.length else { return nil }
            let glyph = manager.glyphIndexForCharacter(at: character)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let anchor = ReadingAnchor(characterIndex: manager.characterIndexForGlyph(at: glyph),
                                       viewportY: rect.minY + textView.textContainerInset.top - textView.contentOffset.y)
            typographyAnchor = anchor
            return anchor
        }

        func restoreReadingAnchor(_ anchor: ReadingAnchor) {
            guard let textView, isValidTextRange(NSRange(location: anchor.characterIndex, length: 1)) else { return }
            let manager = textView.layoutManager
            manager.ensureLayout(forCharacterRange: NSRange(location: anchor.characterIndex, length: 1))
            let glyph = manager.glyphIndexForCharacter(at: anchor.characterIndex)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let target = rect.minY + textView.textContainerInset.top - anchor.viewportY
            guard target.isFinite else { return }
            // UITextView owns content-size layout; do not force full-document
            // layout in both managers merely to restore the visible anchor.
            textView.layoutIfNeeded()
            let lower = -textView.adjustedContentInset.top
            let upper = max(lower, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: max(lower, min(target, upper))), animated: false)
        }

        func cancelResume() {
            resumeTask?.cancel()
            resumeTask = nil
            scheduledRevision = nil
        }

        func scheduleResume() {
            guard let deadline = follow.deadline else { cancelResume(); return }
            guard scheduledRevision != follow.revision else { return }
            cancelResume()
            let revision = follow.revision
            scheduledRevision = revision
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            resumeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, let self, self.textView != nil,
                      self.follow.resumeIfDue(now: ProcessInfo.processInfo.systemUptime, revision: revision) else { return }
                self.cancelResume()
                self.parent.onBrowsingChanged(false)
                self.scrollToCurrentWord(force: true)
                self.reportFollowStatus()
            }
        }

        func returnToCurrentWord() {
            cancelResume()
            typographyAnchor = nil
            follow.returnToCurrentWord()
            scrollToCurrentWord(force: true)
            reportFollowStatus()
        }

        func scrollToCurrentWord(force: Bool) {
            guard !isUpdatingReader, !parent.isSeeking, let textView, let range = lastWordRange, isValidTextRange(range), let band = readingBand?(),
                  force || lastScrolledWordCharIndex != range.location,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            textView.layoutManager.ensureLayout(forCharacterRange: range)
            let rect = textView.firstRect(for: textRange)
            guard !rect.isNull, rect.minY.isFinite, textView.bounds.height > 0 else { return }
            hasDestination = true
            reportFollowStatus()
            lastScrolledWordCharIndex = range.location
            let top = textView.contentOffset.y + band.lowerBound
            let bottom = textView.contentOffset.y + band.upperBound
            var target = textView.contentOffset.y
            if rect.maxY > bottom { target += rect.maxY - bottom }
            else if rect.minY < top { target -= top - rect.minY }
            let maxOffset = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            target = max(-textView.adjustedContentInset.top, min(target, maxOffset))
            if abs(target - textView.contentOffset.y) > 0.5 {
                textView.setContentOffset(CGPoint(x: 0, y: target), animated: !parent.reduceMotion && !UIAccessibility.isVoiceOverRunning)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !isUpdatingReader { typographyAnchor = nil }
            onReaderScroll?()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelResume()
            typographyAnchor = nil
            follow.beginInteraction()
            _ = parent.onSurfaceInteraction()
            parent.onBrowsingChanged(true)
            reportFollowStatus()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { endInteraction() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endInteraction() }

        private func endInteraction() {
            follow.endInteraction(now: ProcessInfo.processInfo.systemUptime)
            scheduleResume()
            reportFollowStatus()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            guard !parent.onSurfaceInteraction() else { return }
            if follow.isBrowsing && !follow.isInteracting {
                follow.endInteraction(now: ProcessInfo.processInfo.systemUptime)
                scheduleResume()
            }
            var point = gesture.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let index = textView.layoutManager.characterIndex(for: point, in: textView.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            guard index < textView.textStorage.length else { return }
            let glyph = textView.layoutManager.glyphIndexForCharacter(at: index)
            let rect = textView.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer)
            guard rect.insetBy(dx: -15, dy: -15).contains(point) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onWordTapped(nil, index)
        }
    }
}

@MainActor final class ReaderViewController<Controls: View>: UIViewController, ReaderDockFrameReceiving {
    private let sourceStorage: NSTextStorage
    let textView: UITextView
    let controlsHost: UIHostingController<Controls>
    var onReaderLayout: ((Bool) -> Void)?
    var onTypographySettled: ((Int) -> Void)?
    private let sharpTextContainer = UIView()
    private let hiddenStatusFallback = ReaderGradientView()
    private var hiddenStatusFallbackGeometry: ReaderHiddenStatusFallbackGeometry?
    private var hiddenStatusFallbackColor: UIColor?
    private var hiddenStatusReducesTransparency = false
    private let sharpMask = ReaderGradientView()
    private let blurMask = ReaderGradientView()
    private var blurredTextHost: UIHostingController<ReaderBlurredText>?
    private var blurredTextContainer: UIView?
    private var mirroredTextView: UITextView?
    private var mirrorViewport: ReaderMirrorViewport?
    private(set) var readingBand: ClosedRange<CGFloat>?
    private var headerClearance: CGFloat = 0
    private var headerViewportWidth: CGFloat = 0
    private(set) var controlsHidden = false
    private weak var dockMeasurement: UIView?
    private var measuredDockFrame: CGRect?
    private var controlsNeedLayout = true
    private var controlsBottomConstraint: NSLayoutConstraint?
    private var controlsLayoutWidth: CGFloat = 0
    private var isLayingOutReader = false
    private struct GeometryKey: Equatable {
        let bounds: CGRect
        let safeArea: UIEdgeInsets
        let header: CGFloat
        let dock: CGRect
        let hasMirror: Bool
    }
    private var lastGeometry: GeometryKey?
    private var needsTextLayout = true
    private var pendingTypographyRevision: Int?
    #if DEBUG
    private let diagnosticsView = UIView()
    struct ChromeSnapshot {
        let textID: ObjectIdentifier
        let mirrorID: ObjectIdentifier?
        let offset: CGPoint
        let inset: UIEdgeInsets
        let band: ClosedRange<CGFloat>?
        let dock: CGRect?
        let hidden: Bool
        let mirrorAlpha: CGFloat
        let sharpEverywhere: Bool
        let statusID: ObjectIdentifier
        let statusVisible: Bool
        let statusGeometry: ReaderHiddenStatusFallbackGeometry?
        let statusAlpha: CGFloat
        let statusColors: [CGColor]
        let statusIsPassive: Bool
    }
    var chromeSnapshot: ChromeSnapshot {
        let colors = sharpMask.gradient.colors as? [CGColor] ?? []
        let opaqueMask = !colors.isEmpty && colors.allSatisfy { $0.alpha == 1 }
        return ChromeSnapshot(textID: ObjectIdentifier(textView), mirrorID: mirroredTextView.map(ObjectIdentifier.init),
                       offset: textView.contentOffset, inset: textView.textContainerInset, band: readingBand,
                       dock: measuredDockFrame, hidden: controlsHidden,
                       mirrorAlpha: blurredTextContainer?.alpha ?? 0,
                       sharpEverywhere: sharpTextContainer.mask == nil || opaqueMask,
                       statusID: ObjectIdentifier(hiddenStatusFallback), statusVisible: !hiddenStatusFallback.isHidden,
                       statusGeometry: hiddenStatusFallbackGeometry, statusAlpha: hiddenStatusFallback.alpha,
                       statusColors: hiddenStatusFallback.gradient.colors as? [CGColor] ?? [],
                       statusIsPassive: !hiddenStatusFallback.isUserInteractionEnabled && hiddenStatusFallback.accessibilityElementsHidden)
    }

    private func updateDiagnostics() {
        guard UIExperimentFixture.readerDiagnosticsEnabled else { return }
        diagnosticsView.frame = CGRect(x: 0, y: view.bounds.midY, width: 1, height: 1)
        let snapshot = chromeSnapshot
        let values: [String: Double] = ["offset": Double(snapshot.offset.y), "top": Double(snapshot.inset.top),
            "bottom": Double(snapshot.inset.bottom), "dockTop": Double(snapshot.dock?.minY ?? 0),
            "dockBottom": Double(snapshot.dock?.maxY ?? 0), "hidden": controlsHidden ? 1 : 0,
            "mirrorAlpha": Double(snapshot.mirrorAlpha), "sharp": snapshot.sharpEverywhere ? 1 : 0,
            "hiddenStatusFallbackVisible": snapshot.statusVisible ? 1 : 0,
            "nativeTopEdgeVisible": textView.topEdgeEffect.isHidden ? 0 : 1,
            "hiddenStatusFallbackBottom": Double(snapshot.statusGeometry?.statusBottom ?? 0),
            "hiddenStatusFallbackEnd": Double(snapshot.statusGeometry?.transitionEnd ?? 0),
            "readerTop": Double(view.convert(view.bounds, to: nil).minY),
            "readerBottom": Double(view.convert(view.bounds, to: nil).maxY),
            "dockWindowBottom": Double(view.convert(snapshot.dock ?? .zero, to: nil).maxY)]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) { diagnosticsView.accessibilityValue = value }
    }
    #endif


    init(controls: Controls) {
        // The reader requires TextKit 1 APIs. Create that system explicitly,
        // rather than converting a live TextKit 2 view on first layout access.
        let storage = NSTextStorage()
        sourceStorage = storage
        let manager = ReaderHighlightLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        textView = UITextView(frame: .zero, textContainer: container)
        manager.highlightTextView = textView
        controlsHost = UIHostingController(rootView: controls)
        super.init(nibName: nil, bundle: nil)
        StabilityTrace.identity("ReaderCreated", textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        sharpTextContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sharpTextContainer)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.showsVerticalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        sharpTextContainer.addSubview(textView)

        addChild(controlsHost)
        // Explicitly invalidate for pill/layout changes, not fixed-size word updates.
        controlsHost.sizingOptions = []
        // UIKit owns the dock's bottom clearance. Do not add SwiftUI's
        // inherited safe-area inset inside this already-positioned host.
        controlsHost.safeAreaRegions = []
        controlsHost.view.backgroundColor = .clear
        controlsHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsHost.view)
        controlsHost.didMove(toParent: self)
        let bottomConstraint = controlsHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        controlsBottomConstraint = bottomConstraint
        updateControlsBottomConstraint()
        NSLayoutConstraint.activate([
            sharpTextContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sharpTextContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sharpTextContainer.topAnchor.constraint(equalTo: view.topAnchor),
            sharpTextContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: sharpTextContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: sharpTextContainer.trailingAnchor),
            textView.topAnchor.constraint(equalTo: sharpTextContainer.topAnchor),
            textView.bottomAnchor.constraint(equalTo: sharpTextContainer.bottomAnchor),
            controlsHost.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controlsHost.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomConstraint
        ])
        textView.bottomEdgeEffect.isHidden = true
        // Default automatic can select a hard toolbar edge for the inline title.
        // Keep the native effect but explicitly soften its reader transition.
        textView.topEdgeEffect.style = .soft
        // Normal operation keeps the same native soft edge in both states.
        // Only Reduce Transparency needs this separate hidden-header fallback.
        hiddenStatusFallback.isHidden = true
        hiddenStatusFallback.isOpaque = false
        hiddenStatusFallback.accessibilityElementsHidden = true
        view.insertSubview(hiddenStatusFallback, belowSubview: controlsHost.view)
        #if DEBUG
        if UIExperimentFixture.readerDiagnosticsEnabled {
            diagnosticsView.isAccessibilityElement = true
            diagnosticsView.accessibilityLabel = "Reader geometry"
            diagnosticsView.accessibilityIdentifier = "fixture.readerGeometry"
            diagnosticsView.accessibilityTraits = .staticText
            diagnosticsView.isUserInteractionEnabled = false
            view.addSubview(diagnosticsView)
        }
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateControlsBottomConstraint()
        if controlsHidden && hiddenStatusReducesTransparency { view.setNeedsLayout() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTopTreatment()
    }

    private func updateControlsBottomConstraint() {
        guard let constraint = controlsBottomConstraint else { return }
        let inset = view.safeAreaInsets.bottom
        let constant = -PlayerDockMetrics.bottomGap(safeAreaInset: inset)
        guard constraint.constant != constant else { return }
        constraint.constant = constant
        controlsNeedLayout = true
        view.setNeedsLayout()
    }

    func configureReader(headerClearance: CGFloat, backgroundColor: UIColor, reduceTransparency: Bool) {
        // Native navigation-bar visibility changes its reported safe area. Keep
        // the visible reading geometry until a genuinely different viewport.
        let widthChanged = headerViewportWidth != view.bounds.width
        headerViewportWidth = view.bounds.width
        let clearance = widthChanged ? max(0, headerClearance) : max(self.headerClearance, headerClearance)
        let geometryChanged = self.headerClearance != clearance ||
            view.backgroundColor != backgroundColor ||
            (blurredTextHost == nil) != reduceTransparency
        self.headerClearance = clearance
        let statusAccessibilityChanged = hiddenStatusReducesTransparency != reduceTransparency
        hiddenStatusReducesTransparency = reduceTransparency
        view.backgroundColor = backgroundColor
        if reduceTransparency {
            removeBlurredText()
        } else if blurredTextHost == nil {
            installBlurredText()
        }
        if statusAccessibilityChanged { updateTopTreatment() }
        if geometryChanged || statusAccessibilityChanged { view.setNeedsLayout() }
    }

    func setControlsHidden(_ hidden: Bool, reduceMotion: Bool) {
        guard controlsHidden != hidden else { return }
        controlsHidden = hidden
        controlsHost.view.isUserInteractionEnabled = !hidden
        controlsHost.view.accessibilityElementsHidden = hidden
        updateTopTreatment()
        let colors = sharpColors(hidden: hidden)
        let from = sharpMask.gradient.presentation()?.colors ?? sharpMask.gradient.colors
        sharpMask.gradient.removeAnimation(forKey: "readerChrome")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sharpMask.gradient.colors = colors
        CATransaction.commit()
        if !reduceMotion {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = from
            animation.toValue = colors
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sharpMask.gradient.add(animation, forKey: "readerChrome")
        }
        let changes = {
            self.controlsHost.view.alpha = hidden ? 0 : 1
            self.blurredTextContainer?.alpha = hidden ? 0 : 1
        }
        if reduceMotion {
            controlsHost.view.layer.removeAllAnimations()
            blurredTextContainer?.layer.removeAllAnimations()
            UIView.performWithoutAnimation(changes)
        } else {
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: changes)
        }
        #if DEBUG
        updateDiagnostics()
        #endif
    }

    private func updateTopTreatment() {
        // Keep the working native renderer enabled when the bar disappears;
        // UIKit owns its normal extent. Never carry the header's measured height
        // into a custom material, mask, content inset, or proxy control.
        guard controlsHidden && hiddenStatusReducesTransparency else {
            if !hiddenStatusFallback.isHidden { hiddenStatusFallback.isHidden = true }
            if textView.topEdgeEffect.isHidden { textView.topEdgeEffect.isHidden = false }
            return
        }
        // Accessibility fallback and the native top effect are mutually exclusive.
        if !textView.topEdgeEffect.isHidden { textView.topEdgeEffect.isHidden = true }
        guard let window = view.window else {
            hiddenStatusFallback.isHidden = true
            return
        }
        var statusBottom = window.bounds.minY + window.safeAreaInsets.top
        if let scene = window.windowScene, let manager = scene.statusBarManager,
           !manager.isStatusBarHidden, !manager.statusBarFrame.isEmpty {
            let statusFrame = window.convert(manager.statusBarFrame, from: scene.effectiveGeometry.coordinateSpace)
            if statusFrame.intersects(window.bounds) { statusBottom = max(statusBottom, statusFrame.maxY) }
        }
        let readerStatusBottom = statusBottom > window.bounds.minY
            ? view.convert(CGPoint(x: window.bounds.midX, y: statusBottom), from: window).y : view.bounds.minY
        let geometry = ReaderHiddenStatusFallbackGeometry(bounds: view.bounds, statusBottom: readerStatusBottom)
        guard !geometry.frame.isEmpty else {
            hiddenStatusFallback.isHidden = true
            return
        }
        let color = view.backgroundColor ?? .clear
        if geometry != hiddenStatusFallbackGeometry || color != hiddenStatusFallbackColor {
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                hiddenStatusFallback.frame = geometry.frame
                hiddenStatusFallback.gradient.colors = [color.cgColor, color.cgColor,
                    color.withAlphaComponent(0.75).cgColor, color.withAlphaComponent(0.25).cgColor,
                    color.withAlphaComponent(0).cgColor]
                hiddenStatusFallback.gradient.locations = geometry.locations
            }
            hiddenStatusFallbackGeometry = geometry
            hiddenStatusFallbackColor = color
        }
        if hiddenStatusFallback.isHidden { hiddenStatusFallback.isHidden = false }
    }

    private func sharpColors(hidden: Bool) -> [CGColor] {
        [UIColor.black.cgColor, UIColor.black.cgColor,
         (hidden ? UIColor.black : UIColor.clear).cgColor,
         (hidden ? UIColor.black : UIColor.clear).cgColor]
    }

    private func installBlurredText() {
        // Share characters and foreground attributes; inherit display-only highlights.
        let layoutManager = ReaderHighlightLayoutManager()
        if let source = textView.layoutManager as? ReaderHighlightLayoutManager {
            layoutManager.setHighlights(source.highlightState)
        }
        let textContainer = NSTextContainer(size: textView.textContainer.size)
        textContainer.lineFragmentPadding = textView.textContainer.lineFragmentPadding
        textContainer.widthTracksTextView = textView.textContainer.widthTracksTextView
        textContainer.heightTracksTextView = textView.textContainer.heightTracksTextView
        textContainer.exclusionPaths = textView.textContainer.exclusionPaths
        layoutManager.addTextContainer(textContainer)
        textView.textStorage.addLayoutManager(layoutManager)
        let mirror = UITextView(frame: .zero, textContainer: textContainer)
        layoutManager.highlightTextView = mirror
        mirror.isEditable = false
        mirror.isSelectable = false
        mirror.isUserInteractionEnabled = false
        mirror.isAccessibilityElement = false
        mirror.accessibilityElementsHidden = true
        mirror.backgroundColor = .clear
        mirror.isOpaque = false
        mirror.contentInsetAdjustmentBehavior = .never
        mirror.showsVerticalScrollIndicator = false
        mirror.showsHorizontalScrollIndicator = false
        mirror.topEdgeEffect.isHidden = true
        mirror.bottomEdgeEffect.isHidden = true
        mirroredTextView = mirror
        StabilityTrace.identity("MirrorCreated", mirror)

        let viewport = ReaderMirrorViewport(textView: mirror)
        mirrorViewport = viewport
        let host = UIHostingController(rootView: ReaderBlurredText(viewport: viewport))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        container.clipsToBounds = true
        container.isHidden = true
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        addChild(host)
        view.insertSubview(container, belowSubview: hiddenStatusFallback)
        container.addSubview(host.view)
        host.didMove(toParent: self)
        blurredTextContainer = container
        blurredTextHost = host
        sharpMask.gradient.colors = sharpColors(hidden: controlsHidden)
        container.alpha = controlsHidden ? 0 : 1
        blurMask.gradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        // Keep the source sharp until a real dock frame has been measured.
        container.mask = blurMask
    }

    private func removeBlurredText() {
        sharpTextContainer.mask = nil
        guard let host = blurredTextHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        blurredTextContainer?.removeFromSuperview()
        host.removeFromParent()
        if let mirror = mirroredTextView {
            textView.textStorage.removeLayoutManager(mirror.layoutManager)
        }
        blurredTextHost = nil
        blurredTextContainer = nil
        mirroredTextView = nil
        mirrorViewport = nil
    }

    func synchronizeBlurredTextOffset() {
        #if DEBUG
        updateDiagnostics()
        #endif
        guard let mirror = mirroredTextView else { return }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Both text views have the same full viewport. Translation belongs
            // to the passive wrapper, never to the scroll offset.
            if mirror.contentOffset != textView.contentOffset {
                mirror.setContentOffset(textView.contentOffset, animated: false)
            }
            CATransaction.commit()
        }
    }

    func invalidateControlsLayout() {
        controlsNeedLayout = true
        controlsHost.view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    func dockMeasurementDidLayout(_ measurement: UIView) {
        let isNew = dockMeasurement !== measurement
        dockMeasurement = measurement
        guard let frame = currentDockFrame() else { return }
        if let previous = measuredDockFrame, previous.size != frame.size {
            invalidateControlsLayout()
        } else if (isNew || frame != measuredDockFrame) && !isLayingOutReader {
            view.setNeedsLayout()
        }
    }

    private func currentDockFrame() -> CGRect? {
        guard let measurement = dockMeasurement, measurement.window != nil,
              measurement.isDescendant(of: controlsHost.view) else { return nil }
        let frame = measurement.convert(measurement.bounds, to: view)
        guard !frame.isNull, !frame.isInfinite, frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    func requestTextLayout(revision: Int) {
        pendingTypographyRevision = revision
        needsTextLayout = true
        view.setNeedsLayout()
    }

    func invalidateHighlightGeometry() {
        for manager in sourceStorage.layoutManagers {
            (manager as? ReaderHighlightLayoutManager)?.invalidateHighlightGeometry()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isLayingOutReader else { return }
        isLayingOutReader = true
        defer { isLayingOutReader = false }
        updateTopTreatment()
        if controlsLayoutWidth != controlsHost.view.bounds.width {
            controlsLayoutWidth = controlsHost.view.bounds.width
            controlsNeedLayout = true
            controlsHost.view.invalidateIntrinsicContentSize()
        }
        if controlsNeedLayout || lastGeometry?.bounds != view.bounds || lastGeometry?.safeArea != view.safeAreaInsets {
            controlsNeedLayout = false
            controlsHost.view.layoutIfNeeded()
        }
        if let frame = currentDockFrame() { measuredDockFrame = frame }
        // Do not invent a dock position while the hosting hierarchy attaches.
        // Retain the last valid measurement through transient layout changes.
        guard let dockFrame = measuredDockFrame else { return }
        let key = GeometryKey(bounds: view.bounds, safeArea: view.safeAreaInsets,
                              header: headerClearance, dock: dockFrame, hasMirror: mirroredTextView != nil)
        let geometryChanged = key != lastGeometry
        guard geometryChanged || needsTextLayout else { return }
        lastGeometry = key
        needsTextLayout = false
        let trace = StabilityTrace.begin("ReaderLayout", revision: pendingTypographyRevision ?? 0)
        defer { StabilityTrace.end("ReaderLayout", trace) }
        var readingGeometryChanged = false
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            // The measured player excludes the optional pill. Sharp text ends
            // at its upper rim; the 16-point crossfade stays inside the player.
            let geometry = ReaderDockGeometry(
                viewportHeight: view.bounds.height,
                dockFrame: dockFrame,
                headerClearance: max(headerClearance, view.safeAreaInsets.top)
            )
            readingGeometryChanged = readingBand != geometry.followBand
            readingBand = geometry.followBand
            let inset = UIEdgeInsets(top: geometry.readingTop, left: 16,
                                    bottom: geometry.trailingScrollInset, right: 16)
            if textView.textContainerInset != inset { textView.textContainerInset = inset }
            textView.layoutIfNeeded()
            if let host = blurredTextHost, let container = blurredTextContainer,
               let mirror = mirroredTextView, let viewport = mirrorViewport {
                let start = geometry.transitionStart
                let transitionEnd = geometry.transitionEnd
                let blurFrame = CGRect(x: view.bounds.minX, y: start, width: view.bounds.width,
                                       height: max(0, view.bounds.height - start))
                if geometryChanged {
                    if container.frame != blurFrame { container.frame = blurFrame }
                    if host.view.frame != container.bounds { host.view.frame = container.bounds }
                    viewport.readerFrame = CGRect(x: 0, y: -start, width: textView.bounds.width,
                                                  height: textView.bounds.height)
                    viewport.layoutIfNeeded()
                    if mirror.textContainerInset != inset { mirror.textContainerInset = inset }
                    if mirror.contentInset != textView.contentInset { mirror.contentInset = textView.contentInset }
                    host.view.layoutIfNeeded()
                    // Match line wrapping; each UITextView lays out its visible
                    // region. Never force both full containers on every layout pass.
                    if mirror.textContainer.size.width != textView.textContainer.size.width {
                        mirror.textContainer.size.width = textView.textContainer.size.width
                    }
                }
                mirror.layoutIfNeeded()

                if geometryChanged {
                    if sharpTextContainer.mask !== sharpMask { sharpTextContainer.mask = sharpMask }
                    container.isHidden = false
                    sharpMask.frame = sharpTextContainer.bounds
                    sharpMask.gradient.locations = [0, NSNumber(value: Double(start / max(1, view.bounds.height))), NSNumber(value: Double(transitionEnd / max(1, view.bounds.height))), 1]
                    blurMask.frame = container.bounds
                    blurMask.gradient.locations = [0, NSNumber(value: Double(min(1, max(0, (transitionEnd - start) / max(1, blurFrame.height))))), 1]
                }
                synchronizeBlurredTextOffset()
            }
        }
        #if DEBUG
        updateDiagnostics()
        #endif
        onReaderLayout?(readingGeometryChanged)
        if let revision = pendingTypographyRevision {
            pendingTypographyRevision = nil
            // Acknowledgement may publish the next appearance snapshot, so it
            // must run outside this UIKit/SwiftUI update and layout transaction.
            DispatchQueue.main.async { [weak self] in self?.onTypographySettled?(revision) }
        }
    }
}

/// SwiftUI supplies a public foreground Gaussian blur; UIKit remains responsible
/// for identical text layout and scrolling. The transparent background is never blurred.
@MainActor private struct ReaderBlurredText: View {
    let viewport: ReaderMirrorViewport

    var body: some View {
        ReaderTextMirror(viewport: viewport)
            .blur(radius: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor private struct ReaderTextMirror: UIViewRepresentable {
    let viewport: ReaderMirrorViewport

    func makeUIView(context: Context) -> ReaderMirrorViewport { viewport }
    func updateUIView(_ uiView: ReaderMirrorViewport, context: Context) {}
}

/// SwiftUI sizes only this clipped viewport; it never resizes the UITextView.
@MainActor private final class ReaderMirrorViewport: UIView {
    private let textView: UITextView
    var readerFrame: CGRect = .zero {
        didSet { if readerFrame != oldValue { setNeedsLayout() } }
    }

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != readerFrame { textView.frame = readerFrame }
    }
}

@MainActor private final class ReaderGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = [0, 1]
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Compact theme-background fallback, used only with Reduce Transparency and
/// a hidden header. Normal native scroll-edge geometry remains system-owned.
struct ReaderHiddenStatusFallbackGeometry: Equatable {
    let bounds: CGRect
    let statusBottom: CGFloat
    let transitionEnd: CGFloat

    init(bounds: CGRect, statusBottom: CGFloat) {
        self.bounds = bounds
        self.statusBottom = min(bounds.maxY, max(bounds.minY, statusBottom))
        transitionEnd = self.statusBottom > bounds.minY ? min(bounds.maxY, self.statusBottom + 32) : bounds.minY
    }

    var frame: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, transitionEnd - bounds.minY))
    }

    var locations: [NSNumber] {
        func location(_ y: CGFloat) -> NSNumber {
            NSNumber(value: Double(min(1, max(0, (y - bounds.minY) / max(1, frame.height)))))
        }
        return [0, location(statusBottom + 4), location(statusBottom + 12), location(statusBottom + 24), 1]
    }
}
