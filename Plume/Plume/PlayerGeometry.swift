import Foundation
import CoreGraphics

enum PlayerDockMetrics {
    static let cornerRadius: CGFloat = 28

    /// Modest overlap into the bottom safe area, with a retained edge gap.
    static func bottomGap(safeAreaInset: CGFloat) -> CGFloat {
        let inset = max(0, safeAreaInset)
        return inset > 0 ? max(12, inset - 14) : 8
    }
}

/// The reachable straight part of the dock rim is also the seek coordinate space.
struct PlayerScrubberGeometry {
    let width: CGFloat
    private var inset: CGFloat { min(PlayerDockMetrics.cornerRadius, max(0, width) / 2) }
    private var span: CGFloat { max(0, width - 2 * inset) }

    func fraction(at x: CGFloat) -> Double {
        guard span > 0 else { return 0 }
        return Double(min(1, max(0, (x - inset) / span)))
    }

    func x(for fraction: Double) -> CGFloat {
        inset + span * CGFloat(min(1, max(0, fraction)))
    }

    /// Include the curved cap only after playback has entered the track.
    func fillWidth(for fraction: Double) -> CGFloat {
        fraction <= 0 ? 0 : fraction >= 1 ? max(0, width) : x(for: fraction)
    }
}

struct ReaderDockGeometry {
    let viewportHeight: CGFloat
    let dockFrame: CGRect
    let headerClearance: CGFloat

    var dockTop: CGFloat { dockFrame.minY }
    var bottomInset: CGFloat { max(0, viewportHeight - dockTop) + 24 }
    var transitionStart: CGFloat { min(viewportHeight, max(readingTop, dockTop)) }
    var transitionEnd: CGFloat { min(viewportHeight, transitionStart + 16) }

    /// Reading space ends where the foreground starts to soften. Trailing
    /// scroll space must not participate in the follow-band calculation.
    var readingTop: CGFloat { headerClearance + 16 }
    var followBand: ClosedRange<CGFloat> {
        let height = max(0, transitionStart - readingTop)
        return (readingTop + height * 0.15)...(readingTop + height * 0.25)
    }
    var trailingScrollInset: CGFloat {
        // At maximum offset, even the last line can reach the band's lower
        // edge. The small margin accommodates text-layout rounding.
        max(bottomInset, viewportHeight - followBand.upperBound + 16)
    }
}

enum PlaybackSeekBounds {
    static func duration(completed: Bool, generated: TimeInterval, estimated: TimeInterval) -> TimeInterval {
        // Streaming and Apple speech retain their existing estimate-based bounds.
        completed ? max(0, generated) : estimated > 0 ? estimated : max(generated, 1)
    }
}
