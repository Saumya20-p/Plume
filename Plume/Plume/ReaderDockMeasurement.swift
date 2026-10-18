import SwiftUI
import UIKit

@MainActor protocol ReaderDockFrameReceiving: AnyObject {
    func dockMeasurementDidLayout(_ measurement: UIView)
}

/// A background marker for the player alone, never the Return pill or its host.
/// UIKit conversion keeps the measurement in the reader's coordinate system.
struct ReaderDockMeasurement: UIViewRepresentable {
    func makeUIView(context: Context) -> ReaderDockMeasurementView { ReaderDockMeasurementView() }
    func updateUIView(_ uiView: ReaderDockMeasurementView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderDockMeasurementView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

@MainActor final class ReaderDockMeasurementView: UIView {
    private weak var receiver: (any ReaderDockFrameReceiving)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        receiver = nil
        reportLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportLayout()
    }

    private func reportLayout() {
        guard window != nil else { return }
        if receiver == nil {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    var ancestor: UIViewController? = controller
                    while let candidate = ancestor {
                        if let receiver = candidate as? any ReaderDockFrameReceiving {
                            self.receiver = receiver
                            break
                        }
                        ancestor = candidate.parent
                    }
                    if receiver != nil { break }
                }
                responder = current.next
            }
        }
        receiver?.dockMeasurementDidLayout(self)
    }
}
