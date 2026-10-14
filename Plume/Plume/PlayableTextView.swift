import SwiftUI
import UIKit

/// Keeps the reading surface, progressive material veil, and dock in one hierarchy.
struct PlayableTextView<Controls: View>: UIViewControllerRepresentable {
    let text: String
    let currentWord: WordTimestamp?
    let readerFont: ReaderFont
    let fontSize: Double
    let isBold: Bool
    let systemBold: Bool
    let contentSizeCategory: UIContentSizeCategory
    let lineSpacing: Double
    let textColor: UIColor
    let backgroundColor: UIColor
    let headerClearance: CGFloat
    let dockHeight: CGFloat
    let reduceTransparency: Bool
    let isWarmTheme: Bool
    let canAutoResume: Bool
    let reduceMotion: Bool
    let returnRequest: Int
    let interactionRequest: Int
    let onBrowsingChanged: (Bool) -> Void
    let onWordTapped: (TimeInterval?, Int) -> Void
    let controls: Controls

    func makeUIViewController(context: Context) -> ReaderViewController<Controls> {
        let controller = ReaderViewController(controls: controls)
        controller.loadViewIfNeeded()
        controller.textView.delegate = context.coordinator
        context.coordinator.textView = controller.textView
        controller.onReaderLayout = { [weak coordinator = context.coordinator] in
            guard let coordinator, !coordinator.follow.isBrowsing,
                  coordinator.parent.canAutoResume || coordinator.lastScrolledWordCharIndex == -1 else { return }
            coordinator.scrollToCurrentWord(force: false)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        controller.textView.addGestureRecognizer(tap)
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController<Controls>, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        controller.controlsHost.rootView = controls
        // Keep UIKit hit bounds in sync when the Return row appears or disappears.
        controller.controlsHost.view.invalidateIntrinsicContentSize()
        controller.overrideUserInterfaceStyle = isWarmTheme ? .light : .dark
        controller.configureReader(
            headerClearance: headerClearance,
            dockHeight: dockHeight,
            backgroundColor: backgroundColor,
            reduceTransparency: reduceTransparency
        )
        let textView = controller.textView
        let font = makeFont()
        let rebuilt = coordinator.lastText != text || coordinator.lastFont != font ||
            coordinator.lastLineSpacing != lineSpacing || coordinator.lastTextColor != textColor ||
            coordinator.lastWarmTheme != isWarmTheme

        if coordinator.lastText != text {
            coordinator.cancelResume()
            coordinator.follow = ReaderFollowContract()
            coordinator.lastScrolledWordCharIndex = -1
        }
        if rebuilt {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = CGFloat(lineSpacing)
            textView.attributedText = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph
            ])
            coordinator.lastText = text
            coordinator.lastFont = font
            coordinator.lastLineSpacing = lineSpacing
            coordinator.lastTextColor = textColor
            coordinator.lastWarmTheme = isWarmTheme
            coordinator.lastWordRange = nil
            coordinator.lastParagraphRange = nil
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
        var newParagraphRange = coordinator.lastParagraphRange
        if rebuilt || coordinator.lastCurrentWord != currentWord {
            newWordRange = nil
            newParagraphRange = nil
            if let word = currentWord, let location = word.rangeLocation, let length = word.rangeLength,
               location >= 0, length >= 0, location <= textView.textStorage.length,
               length <= textView.textStorage.length - location {
                let range = NSRange(location: location, length: length)
                newWordRange = range
                newParagraphRange = (text as NSString).paragraphRange(for: range)
            }
            coordinator.lastCurrentWord = currentWord
        }
        if coordinator.lastWordRange != newWordRange || coordinator.lastParagraphRange != newParagraphRange {
            textView.textStorage.beginEditing()
            if let range = coordinator.lastParagraphRange { textView.textStorage.removeAttribute(.backgroundColor, range: range) }
            if let range = coordinator.lastWordRange {
                textView.textStorage.removeAttribute(.backgroundColor, range: range)
                textView.textStorage.addAttribute(.foregroundColor, value: textColor, range: range)
            }
            if let range = newParagraphRange {
                let color = isWarmTheme ? UIColor(red: 0.40, green: 0.29, blue: 0.22, alpha: 0.09) : UIColor(DesignSystem.accent).withAlphaComponent(0.15)
                textView.textStorage.addAttribute(.backgroundColor, value: color, range: range)
            }
            if let range = newWordRange {
                let color = UIColor(DesignSystem.accent)
                textView.textStorage.addAttribute(.backgroundColor, value: color, range: range)
                textView.textStorage.addAttribute(.foregroundColor, value: UIColor.white, range: range)
            }
            textView.textStorage.endEditing()
            coordinator.lastWordRange = newWordRange
            coordinator.lastParagraphRange = newParagraphRange
        }

        if coordinator.lastReturnRequest != returnRequest {
            coordinator.lastReturnRequest = returnRequest
            coordinator.returnToCurrentWord()
        } else if !coordinator.follow.isBrowsing && (allowed || rebuilt) {
            coordinator.scrollToCurrentWord(force: rebuilt)
        }
    }

    static func dismantleUIViewController(_ controller: ReaderViewController<Controls>, coordinator: Coordinator) {
        coordinator.cancelResume()
        controller.textView.delegate = nil
        controller.onReaderLayout = nil
        coordinator.textView = nil
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
        var parent: PlayableTextView
        weak var textView: UITextView?
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
        var lastParagraphRange: NSRange?
        var lastCurrentWord: WordTimestamp?

        init(_ parent: PlayableTextView) {
            self.parent = parent
            lastReturnRequest = parent.returnRequest
            lastInteractionRequest = parent.interactionRequest
        }

        deinit { resumeTask?.cancel() }

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
            }
        }

        func returnToCurrentWord() {
            cancelResume()
            follow.returnToCurrentWord()
            scrollToCurrentWord(force: true)
        }

        func scrollToCurrentWord(force: Bool) {
            guard let textView, let range = lastWordRange,
                  force || lastScrolledWordCharIndex != range.location,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let rect = textView.firstRect(for: textRange)
            guard !rect.isNull, rect.minY.isFinite, textView.bounds.height > 0 else { return }
            lastScrolledWordCharIndex = range.location
            let visibleHeight = max(1, textView.bounds.height - textView.textContainerInset.top - textView.textContainerInset.bottom)
            let top = textView.contentOffset.y + textView.textContainerInset.top + visibleHeight * 0.15
            let bottom = textView.contentOffset.y + textView.textContainerInset.top + visibleHeight * 0.25
            var target = textView.contentOffset.y
            if rect.maxY > bottom { target += rect.maxY - bottom }
            else if rect.minY < top { target -= top - rect.minY }
            let maxOffset = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            target = max(-textView.adjustedContentInset.top, min(target, maxOffset))
            textView.setContentOffset(CGPoint(x: 0, y: target), animated: !parent.reduceMotion && !UIAccessibility.isVoiceOverRunning)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelResume()
            follow.beginInteraction()
            parent.onBrowsingChanged(true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { endInteraction() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endInteraction() }

        private func endInteraction() {
            follow.endInteraction(now: ProcessInfo.processInfo.systemUptime)
            scheduleResume()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
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

@MainActor final class ReaderViewController<Controls: View>: UIViewController {
    let textView = UITextView()
    let controlsHost: UIHostingController<Controls>
    var onReaderLayout: (() -> Void)?
    private let veil = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let veilMask = ReaderGradientView()
    private let themeFade = ReaderGradientView()
    private var headerClearance: CGFloat = 0
    private var reportedDockHeight: CGFloat = 0
    private var maskTransitionFraction: CGFloat = -1

    init(controls: Controls) {
        controlsHost = UIHostingController(rootView: controls)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.showsVerticalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        // The effect itself is masked; its ancestors remain unmasked and opaque.
        veil.alpha = 1
        veil.isUserInteractionEnabled = false
        let dockMaskColor = UIColor.black.withAlphaComponent(0.97).cgColor
        veilMask.gradient.colors = [UIColor.clear.cgColor, dockMaskColor, dockMaskColor]
        view.addSubview(veil)
        themeFade.isUserInteractionEnabled = false
        view.addSubview(themeFade)

        addChild(controlsHost)
        controlsHost.sizingOptions = .intrinsicContentSize
        controlsHost.view.backgroundColor = .clear
        controlsHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsHost.view)
        controlsHost.didMove(toParent: self)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlsHost.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controlsHost.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controlsHost.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        textView.bottomEdgeEffect.isHidden = true
    }

    func configureReader(headerClearance: CGFloat, dockHeight: CGFloat, backgroundColor: UIColor, reduceTransparency: Bool) {
        self.headerClearance = max(0, headerClearance)
        reportedDockHeight = max(0, dockHeight)
        view.backgroundColor = backgroundColor
        themeFade.gradient.colors = [backgroundColor.withAlphaComponent(0).cgColor, backgroundColor.withAlphaComponent(0.25).cgColor]
        veil.isHidden = reduceTransparency
        themeFade.isHidden = reduceTransparency
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Content still draws beneath the dock, with sufficient measured space
        // for the final line to scroll entirely above the controls.
        let dockHeight = max(0, view.bounds.maxY - controlsHost.view.frame.minY)
        let inset = UIEdgeInsets(top: max(headerClearance, view.safeAreaInsets.top) + 16, left: 16, bottom: dockHeight + 24, right: 16)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        let effectiveDockHeight = reportedDockHeight > 0 ? reportedDockHeight : controlsHost.view.bounds.height
        let dockTop = controlsHost.view.frame.maxY - effectiveDockHeight
        let start = min(view.bounds.maxY, max(headerClearance + 16, dockTop - 72))
        let veilFrame = CGRect(x: view.bounds.minX, y: start, width: view.bounds.width, height: max(0, view.bounds.maxY - start))
        let transitionFraction = min(1, max(0, (dockTop - start) / max(1, veilFrame.height)))
        if veil.frame != veilFrame || maskTransitionFraction != transitionFraction || veil.mask == nil {
            veil.frame = veilFrame
            themeFade.frame = veilFrame
            veilMask.frame = veil.bounds
            // A mask blends the fixed blur with the sharp text underneath.
            // Finish the ramp above the dock, leaving only a faint trace of line structure.
            veilMask.gradient.locations = [0, NSNumber(value: Double(transitionFraction)), 1]
            maskTransitionFraction = transitionFraction
            veilMask.layoutIfNeeded()
            // UIKit copies effect masks. Reassign after resizing the original.
            veil.mask = nil
            veil.mask = veilMask
        }
        onReaderLayout?()
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
