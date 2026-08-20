import SwiftUI

struct SpeedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = AudioPlaybackEngine.shared
    @ObservedObject private var progress = PlaybackProgress.shared
    
    @AppStorage("autoIncreaseSpeedEnabled") private var autoIncreaseSpeedEnabled: Bool = false
    
    private let presets: [Float] = [0.8, 1.0, 1.2, 1.5, 2.0, 2.5]
    
    private var speedLabel: String {
        switch engine.playbackRate {
        case ..<0.9: return "Slower"
        case 0.9...1.1: return "Normal"
        case 1.1..<1.8: return "Faster"
        case 1.8...: return "Very Fast"
        default: return "Normal"
        }
    }
    
    private var remainingDurationString: String {
        let remainingSeconds = max(0, engine.duration - progress.currentTime)
        let effectiveDuration = remainingSeconds / TimeInterval(engine.playbackRate)
        
        if effectiveDuration.isNaN || effectiveDuration.isInfinite {
            return "Duration: ~00:00"
        }
        
        let hours = Int(effectiveDuration) / 3600
        let minutes = (Int(effectiveDuration) % 3600) / 60
        let seconds = Int(effectiveDuration) % 60
        
        if hours > 0 {
            return String(format: "Duration: ~%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "Duration: ~%02d:%02d", minutes, seconds)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 4) {
                        Text(speedLabel)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Text(remainingDurationString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 16)
                    
                    // Stepper
                    HStack(spacing: 40) {
                        Button {
                            let newRate = max(0.75, engine.basePlaybackSpeed - 0.1)
                            setSpeed(newRate)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 44, height: 44)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.primary)
                        .disabled(engine.basePlaybackSpeed <= 0.75)
                        
                        Text(String(format: "%.1f×", engine.playbackRate))
                            .font(.system(size: 40, weight: .bold))
                            .monospacedDigit()
                            .frame(minWidth: 100)
                        
                        Button {
                            let newRate = min(3.0, engine.basePlaybackSpeed + 0.1)
                            setSpeed(newRate)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 44, height: 44)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.primary)
                        .disabled(engine.basePlaybackSpeed >= 3.0)
                    }
                    
                    // Presets Grid
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            ForEach(presets[0..<3], id: \.self) { rate in
                                presetButton(rate: rate)
                            }
                        }
                        HStack(spacing: 12) {
                            ForEach(presets[3..<6], id: \.self) { rate in
                                presetButton(rate: rate)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    // Auto-Increase Toggle
                    VStack(spacing: 16) {
                        Divider()
                        
                        Toggle(isOn: $autoIncreaseSpeedEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Increase Speed Automatically")
                                    .font(.headline)
                                Text("Speed up as you go every 500 words")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(DesignSystem.accent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 24)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }
    
    private func presetButton(rate: Float) -> some View {
        let isSelected = abs(engine.basePlaybackSpeed - rate) < 0.05
        
        return Button {
            setSpeed(rate)
        } label: {
            Text(String(format: "%.1f×", rate))
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isSelected ? DesignSystem.accent : Color(UIColor.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func setSpeed(_ rate: Float) {
        // Round to nearest 0.1 to avoid floating point precision issues
        let roundedRate = (rate * 10).rounded() / 10
        engine.basePlaybackSpeed = roundedRate
    }
}
