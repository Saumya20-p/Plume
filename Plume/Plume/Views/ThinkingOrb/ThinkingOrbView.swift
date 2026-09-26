import SwiftUI

struct ThinkingOrbView: View {
    @State private var isRotating = false
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            Color.clear
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            DesignSystem.accent,
                            DesignSystem.accent.opacity(0.4),
                            DesignSystem.accent.opacity(0.8),
                            DesignSystem.accent
                        ]),
                        center: .center
                    )
                )
                .rotationEffect(Angle(degrees: isRotating ? 360 : 0))
                .scaleEffect(isPulsing ? 1.0 : 0.85)
        }
        .clipShape(Circle())
        .contentShape(Circle())
        .onAppear {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                isRotating = true
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
