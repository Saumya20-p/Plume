import SwiftUI

public enum DesignSystem {
    /// Warm ruby red accent (#A6342A)
    public static let accent = Color("AccentColor")
    
    // Base surface colors for app chrome
    public static let backgroundChrome = Color(UIColor.systemBackground)
    public static let secondaryChrome = Color(UIColor.secondarySystemBackground)
    
    // Standardized corner radii
    public static let cornerRadiusPill: CGFloat = 100
    public static let cornerRadiusCard: CGFloat = 16
    public static let cornerRadiusSheet: CGFloat = 32
}
