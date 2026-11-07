import SwiftUI
import UIKit
import Testing
@testable import Plume

@MainActor struct ReaderChromeTests {
    @Test(arguments: [false, true])
    func hidingOnlyChangesPresentation(reduceTransparency: Bool) throws {
        let controller = ReaderViewController(controls: Color.clear.frame(height: 132))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.textView.attributedText = NSAttributedString(string: String(repeating: "A paragraph of reading text.\n\n", count: 100),
                                                                attributes: [.font: UIFont.systemFont(ofSize: 20)])
        controller.configureReader(headerClearance: 96, backgroundColor: .black, reduceTransparency: reduceTransparency)
        controller.view.layoutIfNeeded()
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 361, height: 132))
        controller.controlsHost.view.addSubview(marker)
        controller.dockMeasurementDidLayout(marker)
        controller.view.layoutIfNeeded()
        controller.textView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let before = controller.chromeSnapshot
        #expect(before.dock != nil)
        #expect(!before.statusVisible)
        #expect(controller.textView.topEdgeEffect.style == .soft)
        #expect(!controller.textView.topEdgeEffect.isHidden)
        for _ in 0..<20 {
            controller.setControlsHidden(true, reduceMotion: true)
            let hidden = controller.chromeSnapshot
            #expect(hidden.sharpEverywhere)
            #expect(hidden.mirrorAlpha == 0)
            #expect(!controller.controlsHost.view.isUserInteractionEnabled)
            #expect(controller.controlsHost.view.accessibilityElementsHidden)
            #expect(hidden.statusID == before.statusID)
            #expect(hidden.statusIsPassive)
            #expect(hidden.statusAlpha == 1)
            #expect(controller.textView.topEdgeEffect.isHidden == reduceTransparency)
            #expect(controller.textView.topEdgeEffect.style == .soft)
            if !reduceTransparency { #expect(!hidden.statusVisible) }
            if reduceTransparency, let geometry = hidden.statusGeometry {
                #expect(hidden.statusVisible)
                #expect(hidden.statusColors.first == UIColor.black.cgColor)
                #expect(hidden.statusColors.map(\.alpha) == [1, 1, 0.75, 0.25, 0])
                #expect(geometry.transitionEnd == min(controller.view.bounds.maxY, geometry.statusBottom + 32))
            }
            // Native toolbar hiding can report a smaller header safe area.
            controller.configureReader(headerClearance: 0, backgroundColor: .black, reduceTransparency: reduceTransparency)
            controller.view.layoutIfNeeded()
            #expect(controller.chromeSnapshot.inset == before.inset)
            controller.setControlsHidden(false, reduceMotion: true)
            #expect(!controller.chromeSnapshot.statusVisible)
            #expect(!controller.textView.topEdgeEffect.isHidden)
            #expect(controller.textView.topEdgeEffect.style == .soft)
        }
        let after = controller.chromeSnapshot
        #expect(after.textID == before.textID)
        #expect(after.mirrorID == before.mirrorID)
        #expect(after.offset == before.offset)
        #expect(after.inset == before.inset)
        #expect(after.band == before.band)
        #expect(after.dock == before.dock)
        #expect(controller.controlsHost.view.isUserInteractionEnabled)
        #expect(!controller.controlsHost.view.accessibilityElementsHidden)
    }

    @Test func hiddenStatusFallbackGeometryIsCompactAndClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let geometry = ReaderHiddenStatusFallbackGeometry(bounds: bounds, statusBottom: 62)
        #expect(geometry.frame == CGRect(x: 0, y: 0, width: 393, height: 94))
        let actualLocations = geometry.locations.map(\.doubleValue)
        let expectedLocations: [Double] = [0, 66.0 / 94, 74.0 / 94, 86.0 / 94, 1]
        #expect(actualLocations == expectedLocations)
        let noStatus = ReaderHiddenStatusFallbackGeometry(bounds: bounds, statusBottom: 0)
        #expect(noStatus.frame.isEmpty)
        let negativeStatus = ReaderHiddenStatusFallbackGeometry(bounds: bounds, statusBottom: -20)
        #expect(negativeStatus.frame.isEmpty)
        let clamped = ReaderHiddenStatusFallbackGeometry(bounds: bounds, statusBottom: 1000)
        #expect(clamped.transitionEnd == bounds.maxY)
        #expect(clamped.locations.allSatisfy { (0...1).contains($0.doubleValue) })
        let shifted = ReaderHiddenStatusFallbackGeometry(bounds: bounds.offsetBy(dx: 0, dy: 20), statusBottom: 82)
        #expect(shifted.frame.height == geometry.frame.height)
        #expect(shifted.locations == geometry.locations)
    }

    private class LocatedTap: UITapGestureRecognizer {
        var point = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { point }
    }

    @Test func hiddenFirstTapIsConsumedAndAutomaticScrollIsNotInteraction() throws {
        let suite = "ReaderChromeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceManager(defaults: defaults)
        var hidden = true
        var interactions = 0
        var seeks = 0
        let parent = PlayableTextView(text: "First word.", documentID: UUID(), currentWord: nil,
            appearanceManager: appearance, typographyRevision: 0, readerFont: .system,
            fontSize: 20, isBold: false, systemBold: false, contentSizeCategory: .large,
            lineSpacing: 4, textColor: .white, backgroundColor: .black, headerClearance: 96,
            showsReturnPill: false, reduceTransparency: true, isWarmTheme: false,
            canAutoResume: true, reduceMotion: true, isSeeking: false, controlsHidden: true,
            onSurfaceInteraction: { let consume = hidden; hidden = false; interactions += 1; return consume },
            onFollowStatusChanged: { _ in }, returnRequest: 0, interactionRequest: 0,
            onBrowsingChanged: { _ in }, onWordTapped: { _, _ in seeks += 1 }, controls: EmptyView())
        let coordinator = parent.makeCoordinator()
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        text.font = .systemFont(ofSize: 20)
        text.text = "First word."
        text.layoutIfNeeded()
        coordinator.textView = text
        let tap = LocatedTap()
        text.addGestureRecognizer(tap)
        let rect = text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: text.textContainer)
        tap.point = CGPoint(x: rect.midX + text.textContainerInset.left, y: rect.midY + text.textContainerInset.top)
        coordinator.handleTap(tap)
        #expect(interactions == 1)
        #expect(seeks == 0)
        coordinator.handleTap(tap)
        #expect(seeks == 1)
        coordinator.scrollViewDidScroll(text)
        #expect(interactions == 2)
        #expect(!coordinator.follow.isBrowsing)
        coordinator.scrollViewWillBeginDragging(text)
        #expect(interactions == 3)
        #expect(coordinator.follow.isBrowsing)
        coordinator.textView = nil
    }
}
