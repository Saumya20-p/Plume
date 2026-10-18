import Foundation
import CoreGraphics
import Testing
@testable import Plume

struct PlayerGeometryTests {
    @Test("A middle-origin drag reaches both inset endpoints", arguments: [CGFloat(320), 370, 408, 852])
    func reachableEndpoints(width: CGFloat) {
        let track = PlayerScrubberGeometry(width: width)
        #expect(track.fraction(at: width / 2) == 0.5)
        #expect(track.fraction(at: 28) == 0)
        #expect(track.fraction(at: width - 28) == 1)
        #expect(track.fraction(at: 0) == 0)
        #expect(track.fraction(at: width) == 1)
        #expect(track.x(for: 0) == 28)
        #expect(track.x(for: 1) == width - 28)
        #expect(track.fillWidth(for: 0) == 0)
        #expect(track.fillWidth(for: 1) == width)
        #expect(abs(track.fraction(at: track.x(for: 0.25)) - 0.25) < 0.000001)
    }

    @Test("Completed audio uses measured bounds; streaming retains estimates", arguments: [
        (true, 120.0, 80.0, 120.0), (true, 80, 120, 80),
        (false, 120, 80, 80), (false, 80, 120, 120),
        (false, 80, 0, 80), (false, 0, 0, 1)
    ])
    func durationBounds(completed: Bool, generated: Double, estimated: Double, expected: Double) {
        #expect(PlaybackSeekBounds.duration(completed: completed, generated: generated, estimated: estimated) == expected)
    }

    @Test("Reader clearance and transition depend only on dock geometry")
    func dockRelativeGeometry() {
        let geometry = ReaderDockGeometry(viewportHeight: 852,
                                          dockFrame: CGRect(x: 16, y: 692, width: 370, height: 118), headerClearance: 96)
        #expect(geometry.dockTop == 692)
        #expect(geometry.bottomInset == 184)
        #expect(geometry.transitionStart == 692)
        #expect(geometry.transitionEnd == 708)
        let largerDock = ReaderDockGeometry(viewportHeight: 852,
                                            dockFrame: CGRect(x: 16, y: 610, width: 370, height: 200), headerClearance: 96)
        #expect(largerDock.bottomInset == 266)
        #expect(largerDock.transitionStart == 610)
        #expect(largerDock.transitionEnd == 626)
    }
}
