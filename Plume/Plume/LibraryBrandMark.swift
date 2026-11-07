import SwiftUI

/// Flat source artwork; the system app icon's tile and lighting stay out of content.
struct LibraryBrandMark: View {
    let waveReveal: CGFloat
    let isStatic: Bool

    var body: some View {
        ZStack {
            Image(.libraryQuill)
                .resizable()
                .scaledToFit()
            Image(.libraryQuillTip)
                .resizable()
                .scaledToFit()
                .opacity(0.7)
            Image(.libraryPenHolder)
                .resizable()
                .scaledToFit()
                .foregroundStyle(DesignSystem.accent)
            Image(.libraryInkWave)
                .resizable()
                .scaledToFit()
                .foregroundStyle(DesignSystem.accent)
                .mask {
                    if isStatic {
                        Rectangle()
                    } else {
                        Rectangle().scaleEffect(x: waveReveal, y: 1, anchor: .leading)
                    }
                }
        }
        .foregroundStyle(.primary)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
