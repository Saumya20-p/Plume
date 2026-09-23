import SwiftUI
import SwiftData
import AVFoundation
import Combine

struct PlayerView: View {
    @Bindable var document: Document
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    @ObservedObject private var progress = PlaybackProgress.shared
    @ObservedObject private var generationManager = AudioGenerationManager.shared
    
    @State private var showAppearanceSettings = false
    @State private var showQueueSheet = false
    @State private var isExplicitlyDismissing = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearanceManager = AppearanceManager.shared
    
    var body: some View {
        let activeTheme = appearanceManager.activeTheme(colorScheme: colorScheme)
        
        ZStack(alignment: .bottom) {
            activeTheme.backgroundColor.ignoresSafeArea()
            
            // ALWAYS show the text
            PlayableTextView(
                text: document.bodyText,
                currentWord: progress.currentWord,
                estimatedDuration: document.estimatedDuration,
                fontFamily: appearanceManager.fontFamily,
                fontSize: appearanceManager.fontSize,
                isBold: appearanceManager.isBold,
                lineSpacing: appearanceManager.lineSpacing,
                textColor: UIColor(activeTheme.textColor),
                backgroundColor: UIColor(activeTheme.backgroundColor),
                onWordTapped: { _, charIndex in
                    playbackEngine.seek(toCharIndex: charIndex)
                    if !playbackEngine.isPlaying {
                        playbackEngine.play()
                    }
                }
            )
            .equatable()
            .ignoresSafeArea(edges: [.top, .bottom])
            
            // --- BOTTOM VEIL (True Progressive Blur) ---
            VariableBlurView(direction: .bottomToTop, maxBlurRadius: 10)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.8), location: 0.6),
                            .init(color: .black.opacity(0.9), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 240)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            
            // --- THEME-MATCHING FADE ---
            LinearGradient(
                stops: [
                    .init(color: activeTheme.backgroundColor.opacity(0.0), location: 0.0),
                    .init(color: activeTheme.backgroundColor.opacity(0.85), location: 0.6),
                    .init(color: activeTheme.backgroundColor.opacity(0.95), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            
            PlayerControlsView(
                document: document,
                playbackEngine: playbackEngine,
                generationManager: generationManager,
                showQueueSheet: $showQueueSheet,
                onDismiss: {
                    isExplicitlyDismissing = true
                    playbackEngine.presentedPlayerDocument = nil
                    dismiss()
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    isExplicitlyDismissing = true
                    playbackEngine.presentedPlayerDocument = nil
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAppearanceSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .sheet(isPresented: $showQueueSheet) {
            QueueSheetView()
        }
        .sheet(isPresented: $showAppearanceSettings) {
            AppearanceSettingsView()
                .environmentObject(appearanceManager)
        }
        .onAppear {
            playbackEngine.isPlayerViewPresented = true
            
            if playbackEngine.currentDocument?.id != document.id {
                // Immediately cut off the old audio and stop generating when switching chapters
                playbackEngine.pause()
                generationManager.cancelCurrentGeneration()
                playbackEngine.load(document: document)
                
                if document.lastReadCharIndex > 0 {
                    PlaybackProgress.shared.currentWord = WordTimestamp(word: "", startTime: 0, endTime: 0, rangeLocation: document.lastReadCharIndex, rangeLength: 0)
                } else {
                    PlaybackProgress.shared.currentWord = nil
                }
            }
            
            if document.audioFileURL != nil || playbackEngine.isAppleActive {
                if !playbackEngine.isPlaying {
                    playbackEngine.play()
                }
            }
        }
        .onDisappear {
            playbackEngine.isPlayerViewPresented = false
            // Don't cancel if audio has finished generating or if we are actively playing and backgrounding.
            // Only cancel in-flight work if the user explicitly closed the player and playback is stopped.
            if isExplicitlyDismissing && !playbackEngine.isPlaying {
                if generationManager.generatingDocumentIDs.contains(document.id) {
                    generationManager.cancelCurrentGeneration()
                }
            }
        }
        .alert(
            "Generation Error",
            isPresented: Binding(
                get: { generationManager.lastError != nil },
                set: { if !$0 { generationManager.lastError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                if let error = generationManager.lastError {
                    Text(error)
                }
            }
        )
    }
}

struct PlayerControlsView: View {
    let document: Document
    @ObservedObject var playbackEngine: AudioPlaybackEngine
    @ObservedObject var progress = PlaybackProgress.shared
    @ObservedObject var generationManager: AudioGenerationManager
    @Binding var showQueueSheet: Bool
    var onDismiss: () -> Void
    @State private var showSpeedSheet = false
    @State private var showVoiceSheet = false
    @State private var coverImage: UIImage?
    private func formatTime(_ time: TimeInterval) -> String {
        let min = Int(time) / 60
        let sec = Int(time) % 60
        return String(format: "%02d:%02d", min, sec)
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Top Row
            HStack {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showQueueSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ScaleButtonStyle())
                
                Spacer()
                
                VStack(alignment: .center, spacing: 2) {
                    let speed = Double(playbackEngine.playbackRate)
                    let isFullyGenerated = document.audioFileURL != nil
                    let currentTimeStr = formatTime(progress.currentTime / speed)
                    let totalTimeStr = isFullyGenerated ? formatTime(playbackEngine.duration / speed) : "~\(formatTime(document.estimatedDuration / speed))"
                    
                    Text("\(currentTimeStr) / \(totalTimeStr)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    playbackEngine.pause()
                    if generationManager.generatingDocumentIDs.contains(document.id) {
                        generationManager.cancelCurrentGeneration()
                    }
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            
            // Bottom Row
            HStack(spacing: 0) {
                // Speed Button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSpeedSheet = true
                }) {
                    Text(String(format: "%.1fx", playbackEngine.playbackRate))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                
                Spacer()
                
                let interval = UserDefaults.standard.integer(forKey: "defaultSkipInterval")
                let skipVal = interval == 0 ? 15 : interval
                
                Button(action: { 
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    playbackEngine.skipBackward() 
                }) {
                    Image(systemName: "gobackward.\(skipVal)")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                
                Spacer()
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if !playbackEngine.isAppleActive && playbackEngine.chunks.isEmpty && document.audioFileURL == nil && !generationManager.generatingDocumentIDs.contains(document.id) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            let resumeIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? document.lastReadCharIndex
                            if resumeIndex > 0 {
                                playbackEngine.seek(toCharIndex: resumeIndex)
                                playbackEngine.isPlaying = true
                            } else {
                                generationManager.generate(document: document, playbackEngine: playbackEngine)
                            }
                        }
                    } else {
                        playbackEngine.togglePlayPause()
                    }
                }) {
                    Group {
                        if !playbackEngine.isAppleActive && generationManager.generatingDocumentIDs.contains(document.id) && playbackEngine.chunks.isEmpty && document.audioFileURL == nil {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(DesignSystem.accent)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle())
                
                Spacer()
                
                Button(action: { 
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    playbackEngine.skipForward() 
                }) {
                    Image(systemName: "goforward.\(skipVal)")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                
                Spacer()
                
                // Voice Button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showVoiceSheet = true
                }) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16) 
        .padding(.top, 16)
        .contentShape(Rectangle()) // Capture all taps so they don't fall through to text!
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(alignment: .top) {
            LiveEdgeScrubber(
                currentTime: $progress.currentTime,
                generatedDuration: playbackEngine.duration,
                estimatedDuration: document.estimatedDuration,
                isFullyGenerated: document.audioFileURL != nil,
                onSeek: { targetTime in
                    playbackEngine.seek(to: targetTime)
                }
            )
            // No offset needed if we want it completely inside the top edge, or offset slightly but clip it
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)

        .sheet(isPresented: $showSpeedSheet) {
            SpeedSettingsView()
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSelectionSheetView(document: document, playbackEngine: playbackEngine)
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.5, blendDuration: 0.5), value: configuration.isPressed)
    }
}

struct LiveEdgeScrubber: View {
    @Binding var currentTime: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let isFullyGenerated: Bool
    let onSeek: (TimeInterval) -> Void
    
    @State private var dragTime: TimeInterval? = nil
    @State private var isDragging: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            let totalTime = isFullyGenerated ? generatedDuration : estimatedDuration
            let validTotal = totalTime > 0 ? totalTime : 1
            
            let displayTime = dragTime ?? currentTime
            let progressRatio = CGFloat(displayTime / validTotal)
            let bufferRatio = isFullyGenerated ? 1.0 : CGFloat(generatedDuration / validTotal)
            let barHeight: CGFloat = 3
            
            ZStack(alignment: .topLeading) {
                // Background Track
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: barHeight)
                    .clipShape(Capsule())
                
                // Buffer Track
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: max(0, geometry.size.width * min(1.0, bufferRatio)), height: barHeight)
                    .clipShape(Capsule())
                
                // Active Progress
                Rectangle()
                    .fill(DesignSystem.accent)
                    .frame(width: max(0, geometry.size.width * min(1.0, progressRatio)), height: barHeight)
                    .clipShape(Capsule())
                
                // Playhead Thumb (only visible when dragging for a cleaner look)
                if isDragging {
                    Circle()
                        .fill(DesignSystem.accent)
                        .shadow(radius: 2)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, geometry.size.width * min(1.0, progressRatio) - 6), y: -4.5)
                }
            }
            .frame(height: 44, alignment: .top) // 44px height for visual bounds
            .overlay(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle()) // Capture touches in the transparent area
                    .frame(height: 24) // Restrict height to the top padding so it doesn't block buttons!
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                // Direct mapping across the full width
                                let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                let targetTime = fraction * validTotal
                                dragTime = targetTime
                            }
                            .onEnded { _ in
                                isDragging = false
                                if let finalTime = dragTime {
                                    onSeek(finalTime)
                                }
                                dragTime = nil
                            }
                    )
            }
        }
        .frame(height: 44)
    }
}


struct VoiceSelectionSheetView: View {
    let document: Document
    @ObservedObject var playbackEngine: AudioPlaybackEngine
    
    var body: some View {
        NavigationStack {
            VoiceSettingsView(document: document, playbackEngine: playbackEngine)
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .large))
    }
}

