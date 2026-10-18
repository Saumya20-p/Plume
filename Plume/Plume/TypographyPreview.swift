import UIKit

/// A reusable display link with one replaceable callback, paused between work.
@MainActor final class TypographyPreview {
    private var pending: (() -> Void)?
    private var displayLink: CADisplayLink?

    isolated deinit { displayLink?.invalidate() }

    func schedule(_ update: @escaping () -> Void) {
        pending = update
        if displayLink == nil {
            let link = CADisplayLink(target: Target(owner: self), selector: #selector(Target.tick(_:)))
            link.isPaused = true
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
        displayLink?.isPaused = false
    }

    private func applyLatest() {
        let update = pending
        pending = nil
        displayLink?.isPaused = true
        update?()
    }

    private final class Target: NSObject {
        weak var owner: TypographyPreview?
        init(owner: TypographyPreview) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.applyLatest()
        }
    }
}
