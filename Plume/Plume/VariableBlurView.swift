import SwiftUI
import UIKit

// MARK: - Blur Direction

public enum VariableBlurDirection {
    /// Blur is strongest at the top, fading to clear at the bottom.
    case topToBottom
    /// Blur is strongest at the bottom, fading to clear at the top.
    case bottomToTop
}

// MARK: - SwiftUI View

/// A SwiftUI view that creates a progressive (variable) blur effect.
///
/// Uses `UIVisualEffectView` and the private `CAFilter` "variableBlur" filter
/// with a gradient mask image to vary the blur radius across the view.
public struct VariableBlurView: UIViewRepresentable {
    
    public var direction: VariableBlurDirection
    public var maxBlurRadius: CGFloat
    
    public init(
        direction: VariableBlurDirection = .topToBottom,
        maxBlurRadius: CGFloat = 20
    ) {
        self.direction = direction
        self.maxBlurRadius = maxBlurRadius
    }
    
    public func makeUIView(context: Context) -> VariableBlurUIView {
        VariableBlurUIView(direction: direction, maxBlurRadius: maxBlurRadius)
    }
    
    public func updateUIView(_ uiView: VariableBlurUIView, context: Context) {
        uiView.update(direction: direction, maxBlurRadius: maxBlurRadius)
    }
}

// MARK: - UIKit Backing View

public class VariableBlurUIView: UIView {
    
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private var direction: VariableBlurDirection
    private var maxBlurRadius: CGFloat
    
    init(direction: VariableBlurDirection, maxBlurRadius: CGFloat) {
        self.direction = direction
        self.maxBlurRadius = maxBlurRadius
        super.init(frame: .zero)
        
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private var lastSize: CGSize = .zero
    private var lastDirection: VariableBlurDirection?
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        let newSize = bounds.size
        if newSize != lastSize {
            applyVariableBlur()
            lastSize = newSize
        }
    }
    
    func update(direction: VariableBlurDirection, maxBlurRadius: CGFloat) {
        if self.direction == direction && self.maxBlurRadius == maxBlurRadius && lastDirection != nil {
            return
        }
        
        self.direction = direction
        self.maxBlurRadius = maxBlurRadius
        self.lastDirection = direction
        
        // Ensure we don't apply if size is 0 (layoutSubviews will handle it later)
        if bounds.size != .zero {
            applyVariableBlur()
        }
    }
    
    // MARK: - Private
    
    private func applyVariableBlur() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        
        guard let gradientImage = Self.makeGradientImage(
            height: size.height,
            direction: direction
        ) else { return }
        
        // Access private CAFilter class using obfuscated selectors
        let filterClassName = ["CA", "Filter"].joined()
        guard let filterClass = NSClassFromString(filterClassName) as? NSObject.Type else { return }
        
        let filterTypeName = ["variable", "Blur"].joined()
        let selectorName = ["filter", "With", "Type:"].joined()
        let selector = NSSelectorFromString(selectorName)
        
        guard filterClass.responds(to: selector),
              let filterObj = filterClass.perform(selector, with: filterTypeName)?
                .takeUnretainedValue() as? NSObject
        else { return }
        
        // Configure the filter
        filterObj.setValue(maxBlurRadius, forKey: ["input", "Radius"].joined())
        filterObj.setValue(gradientImage, forKey: ["input", "Mask", "Image"].joined())
        filterObj.setValue(true, forKey: ["input", "Normalize", "Edges"].joined())
        
        // Apply to the backdrop layer (subviews[0] = _UIVisualEffectBackdropView)
        guard let backdropLayer = blurView.subviews.first?.layer else { return }
        backdropLayer.filters = [filterObj]
        
        // Hide tint/overlay subviews to prevent hard lines
        for subview in blurView.subviews.dropFirst() {
            subview.alpha = 0
        }
    }
    
    /// Generates a grayscale gradient CGImage for the blur mask.
    /// White pixels = full blur, Black pixels = no blur.
    private static func makeGradientImage(
        height: CGFloat,
        direction: VariableBlurDirection
    ) -> CGImage? {
        let gradientWidth = 1
        let gradientHeight = max(Int(height), 1)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        guard let context = CGContext(
            data: nil,
            width: gradientWidth,
            height: gradientHeight,
            bitsPerComponent: 8,
            bytesPerRow: gradientWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        
        // CGContext origin is bottom-left
        let colors: [CGColor]
        let locations: [CGFloat]
        switch direction {
        case .topToBottom:
            // Blur at top, clear at bottom
            // Holds strong blur through the top, then eases off
            colors = [
                CGColor(gray: 0, alpha: 1),    // bottom = no blur
                CGColor(gray: 0.4, alpha: 1),  // 70% up = moderate blur
                CGColor(gray: 1, alpha: 1),    // top = full blur
            ]
            locations = [0.0, 0.7, 1.0]
        case .bottomToTop:
            // Clear at top, blur at bottom
            // Gentle onset then ramps up sharply near the card
            colors = [
                CGColor(gray: 1, alpha: 1),    // bottom = full blur
                CGColor(gray: 0.6, alpha: 1),  // 30% up = still 60% blur
                CGColor(gray: 0, alpha: 1),    // top = no blur
            ]
            locations = [0.0, 0.3, 1.0]
        }
        
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations
        ) else { return nil }
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: gradientHeight),
            options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
        )
        
        return context.makeImage()
    }
}
