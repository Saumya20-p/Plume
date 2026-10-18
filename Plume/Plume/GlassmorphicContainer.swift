import SwiftUI
import UIKit

public struct GlassmorphicContainer: ViewModifier {
    public var material: Material
    public var cornerRadius: CGFloat
    private var dockReduceTransparency: Bool?
    
    public init(material: Material = .regularMaterial, cornerRadius: CGFloat = DesignSystem.cornerRadiusCard) {
        self.material = material
        self.cornerRadius = cornerRadius
    }

    /// Internal player styling leaves the public initializer/defaults intact.
    static func playerDock(cornerRadius: CGFloat, reduceTransparency: Bool) -> Self {
        var modifier = Self(cornerRadius: cornerRadius)
        modifier.dockReduceTransparency = reduceTransparency
        return modifier
    }
    
    public func body(content: Content) -> some View {
        if let reduceTransparency = dockReduceTransparency {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if reduceTransparency {
                let surface = UIColor.secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                content
                    .background(Color(uiColor: surface), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
            } else if #available(iOS 26, *) {
                // One native surface supplies its own lighting and shadow.
                // Do not add an outer clip or whole-dock interactivity.
                content.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            } else {
                content
                    .background(material, in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
            }
        } else if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
        } else {
            content
                .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
        }
    }
}

public extension View {
    func glassmorphic(material: Material = .regularMaterial, cornerRadius: CGFloat = DesignSystem.cornerRadiusCard) -> some View {
        self.modifier(GlassmorphicContainer(material: material, cornerRadius: cornerRadius))
    }
}
