import SwiftUI
import UIKit
import AVFoundation

struct PlayableTextView: UIViewRepresentable, Equatable {
    let text: String
    let currentWord: WordTimestamp?
    let estimatedDuration: TimeInterval
    
    let fontFamily: String
    let fontSize: Double
    let isBold: Bool
    let lineSpacing: Double
    let textColor: UIColor
    let backgroundColor: UIColor
    
    let onWordTapped: (TimeInterval?, Int) -> Void
    
    static func == (lhs: PlayableTextView, rhs: PlayableTextView) -> Bool {
        return lhs.text == rhs.text &&
               lhs.currentWord == rhs.currentWord &&
               lhs.fontFamily == rhs.fontFamily &&
               lhs.fontSize == rhs.fontSize &&
               lhs.isBold == rhs.isBold &&
               lhs.lineSpacing == rhs.lineSpacing &&
               lhs.textColor == rhs.textColor &&
               lhs.backgroundColor == rhs.backgroundColor &&
               lhs.estimatedDuration == rhs.estimatedDuration
    }
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 280, right: 16)
        textView.showsVerticalScrollIndicator = false
        textView.delegate = context.coordinator
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tapGesture)
        
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        
        let baseFont = UIFont(name: fontFamily, size: CGFloat(fontSize)) ?? UIFont.systemFont(ofSize: CGFloat(fontSize))
        var traitCollection: UIFontDescriptor.SymbolicTraits = []
        if isBold { traitCollection.insert(.traitBold) }
        
        let fontDescriptor = baseFont.fontDescriptor.withSymbolicTraits(traitCollection) ?? baseFont.fontDescriptor
        let font = UIFont(descriptor: fontDescriptor, size: CGFloat(fontSize))
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(lineSpacing)
        
        // 1. Check if full rebuild is needed
        let styleChanged = coordinator.lastFontFamily != fontFamily ||
                           coordinator.lastFontSize != fontSize ||
                           coordinator.lastIsBold != isBold ||
                           coordinator.lastLineSpacing != lineSpacing ||
                           coordinator.lastTextColor != textColor ||
                           coordinator.lastText != text
        
        if styleChanged || uiView.attributedText == nil || uiView.attributedText.length == 0 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
            
            uiView.attributedText = NSAttributedString(string: text, attributes: attributes)
            
            coordinator.lastText = text
            coordinator.lastFontFamily = fontFamily
            coordinator.lastFontSize = fontSize
            coordinator.lastIsBold = isBold
            coordinator.lastLineSpacing = lineSpacing
            coordinator.lastTextColor = textColor
            coordinator.lastWordRange = nil
            coordinator.lastParagraphRange = nil
            coordinator.lastScrolledWordCharIndex = -1
        }
        
        // 2. Find current word using passed index
        let currentWord = self.currentWord
        
        // 3. Update highlights efficiently
        let wordChanged = coordinator.lastCurrentWord != currentWord
        
        var newWordRange: NSRange? = coordinator.lastWordRange
        var newParagraphRange: NSRange? = coordinator.lastParagraphRange
        
        // Only run the heavy string math if the word actually changed or text rebuilt
        if styleChanged || wordChanged {
            newWordRange = nil
            newParagraphRange = nil
            
            if let currentWord = currentWord, let loc = currentWord.rangeLocation, let len = currentWord.rangeLength {
                let nsRange = NSRange(location: loc, length: len)
                if nsRange.location + nsRange.length <= text.utf16.count {
                    newWordRange = nsRange
                    let nsString = text as NSString
                    newParagraphRange = nsString.paragraphRange(for: nsRange)
                }
            }
            coordinator.lastCurrentWord = currentWord
        }
        
        let needsUpdate = coordinator.lastWordRange != newWordRange || coordinator.lastParagraphRange != newParagraphRange
        
        if needsUpdate {
            uiView.textStorage.beginEditing()
            
            // Unhighlight previous
            if let oldParagraph = coordinator.lastParagraphRange {
                uiView.textStorage.removeAttribute(.backgroundColor, range: oldParagraph)
            }
            if let oldWord = coordinator.lastWordRange {
                uiView.textStorage.removeAttribute(.backgroundColor, range: oldWord)
                uiView.textStorage.removeAttribute(.foregroundColor, range: oldWord)
                uiView.textStorage.addAttribute(.foregroundColor, value: textColor, range: oldWord)
            }
            
            // Highlight new
            if let newParagraph = newParagraphRange {
                uiView.textStorage.addAttribute(.backgroundColor, value: UIColor(DesignSystem.accent).withAlphaComponent(0.2), range: newParagraph)
            }
            if let newWord = newWordRange {
                uiView.textStorage.addAttribute(.backgroundColor, value: UIColor(DesignSystem.accent), range: newWord)
                uiView.textStorage.addAttribute(.foregroundColor, value: UIColor.white, range: newWord)
            }
            
            uiView.textStorage.endEditing()
            coordinator.lastWordRange = newWordRange
            coordinator.lastParagraphRange = newParagraphRange
        }
        
        // 4. Auto-scroll logic
        if !coordinator.isUserScrolling, let nsRange = newWordRange, let currentWord = currentWord, let loc = currentWord.rangeLocation {
            // Only scroll if this is a new word
            if coordinator.lastScrolledWordCharIndex != loc {
                coordinator.lastScrolledWordCharIndex = loc
                
                // Slight delay to ensure layout is done
                DispatchQueue.main.async {
                    if let textPositionStart = uiView.position(from: uiView.beginningOfDocument, offset: nsRange.location),
                       let textPositionEnd = uiView.position(from: textPositionStart, offset: nsRange.length),
                       let textRange = uiView.textRange(from: textPositionStart, to: textPositionEnd) {
                        
                        let rect = uiView.firstRect(for: textRange) // Bounding box of the word
                        
                        // Define the Focus Zone (top 15-25% of the screen)
                        let focusZoneTop = uiView.contentOffset.y + (uiView.bounds.height * 0.15)
                        let focusZoneBottom = uiView.contentOffset.y + (uiView.bounds.height * 0.25)
                        
                        var targetOffset: CGPoint? = nil
                        
                        if rect.maxY > focusZoneBottom {
                            let requiredShift = rect.maxY - focusZoneBottom
                            targetOffset = CGPoint(x: 0, y: uiView.contentOffset.y + requiredShift)
                        } else if rect.minY < focusZoneTop {
                            let requiredShift = focusZoneTop - rect.minY
                            targetOffset = CGPoint(x: 0, y: uiView.contentOffset.y - requiredShift)
                        }
                        
                        if let target = targetOffset {
                            let maxOffsetY = max(-uiView.adjustedContentInset.top, uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom)
                            let clampedY = max(-uiView.adjustedContentInset.top, min(target.y, maxOffsetY))
                            uiView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: true)
                        }
                    }
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlayableTextView
        var lastScrolledWordCharIndex: Int = -1
        var isUserScrolling: Bool = false
        var scrollResumeTimer: Timer?
        
        var lastText: String?
        var lastFontFamily: String?
        var lastFontSize: Double?
        var lastIsBold: Bool?
        var lastLineSpacing: Double?
        var lastTextColor: UIColor?
        var lastWordRange: NSRange?
        var lastParagraphRange: NSRange?
        var lastCurrentWord: WordTimestamp?
        
        init(_ parent: PlayableTextView) {
            self.parent = parent
        }
        
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            scrollResumeTimer?.invalidate()
            scrollResumeTimer = nil
        }
        
        private func scheduleResumeTimer() {
            scrollResumeTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.isUserScrolling = false
                self.lastScrolledWordCharIndex = -1 // Force an immediate re-center on the next word tick
            }
            timer.tolerance = 0.3
            scrollResumeTimer = timer
        }
        
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                scheduleResumeTimer()
            }
        }
        
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scheduleResumeTimer()
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            
            var location = gesture.location(in: textView)
            location.x -= textView.textContainerInset.left
            location.y -= textView.textContainerInset.top
            
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            
            let characterIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            guard characterIndex < textView.textStorage.length else { return }
            
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let boundingRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            if !boundingRect.insetBy(dx: -15, dy: -15).contains(location) { return }
            
            // Always pass the character index, AudioPlaybackEngine will find the timestamp
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onWordTapped(nil, characterIndex)
        }
    }
}
