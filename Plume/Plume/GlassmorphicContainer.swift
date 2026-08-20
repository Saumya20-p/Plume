import SwiftUI

public struct GlassmorphicContainer: ViewModifier {
    public var material: Material
    public var cornerRadius: CGFloat
    
    public init(material: Material = .regularMaterial, cornerRadius: CGFloat = DesignSystem.cornerRadiusCard) {
        self.material = material
        self.cornerRadius = cornerRadius
    }
    
    public func body(content: Content) -> some View {
        if #available(iOS 26, *) {
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
