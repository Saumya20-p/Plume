import SwiftUI

public enum DesignSystem {
    /// Lively Rosewood accent
    public static let accent = Color(hex: "#AF3E4D")
    
    // Base surface colors for app chrome
    public static let backgroundChrome = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark ? UIColor(Color(hex: "#2E2E2E")) : UIColor(Color(hex: "#F1ECE6"))
    })
    
    public static let secondaryChrome = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark ? UIColor(Color(hex: "#3A3A3A")) : UIColor(Color(hex: "#DDD5CD"))
    })
    
    // Standardized corner radii
    public static let cornerRadiusPill: CGFloat = 100
    public static let cornerRadiusCard: CGFloat = 16
    public static let cornerRadiusSheet: CGFloat = 32
}
