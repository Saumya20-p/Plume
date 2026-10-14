import SwiftUI
import SwiftData
import AVFoundation
import Combine

struct PlayerView: View, Equatable {
    static func == (lhs: PlayerView, rhs: PlayerView) -> Bool {
        return lhs.document.id == rhs.document.id
    }
    @Bindable var document: Document
    @ObservedObject private var playbackEngine = AudioPlaybackEngine.shared
    @ObservedObject private var progress = PlaybackProgress.shared
    @ObservedObject private var generationManager = AudioGenerationManager.shared
    
    @State private var showAppearanceSettings = false
    @State private var showQueueSheet = false
    @State private var isExplicitlyDismissing = false
    @State private var isBrowsing = false
    @State private var returnRequest = 0
    @State private var interactionRequest = 0
    @State private var controlsSheetPresented = false
    @State private var readerVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearanceManager = AppearanceManager.shared
    
    var body: some View {
        let activeTheme = appearanceManager.activeTheme(colorScheme: colorScheme)
        
        PlayableTextView(
            text: document.bodyText,
            currentWord: progress.currentWord,
            readerFont: appearanceManager.readerFont,
            fontSize: appearanceManager.fontSize,
            isBold: appearanceManager.isBold,
            systemBold: legibilityWeight == .bold,
            contentSizeCategory: dynamicTypeSize.uiContentSizeCategory,
            lineSpacing: appearanceManager.lineSpacing,
            textColor: UIColor(activeTheme.textColor),
            backgroundColor: UIColor(activeTheme.backgroundColor),
            isWarmTheme: activeTheme == .warm,
            canAutoResume: readerVisible && playbackEngine.isPlaying && scenePhase == .active &&
                !showQueueSheet && !showAppearanceSettings && !controlsSheetPresented && !voiceOverEnabled,
            reduceMotion: reduceMotion,
            returnRequest: returnRequest,
            interactionRequest: interactionRequest,
            onBrowsingChanged: { isBrowsing = $0 },
            onWordTapped: { _, charIndex in
                playbackEngine.seek(toCharIndex: charIndex)
                if !playbackEngine.isPlaying { playbackEngine.play() }
            },
            controls: VStack(spacing: 8) {
                if isBrowsing {
                    Button("Return to Current Word", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        isBrowsing = false
                        returnRequest += 1
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityHint("Moves the reader to the spoken word")
                }
                PlayerControlsView(
                    document: document,
                    playbackEngine: playbackEngine,
                    generationManager: generationManager,
                    showQueueSheet: $showQueueSheet,
                    onSheetPresentationChanged: { controlsSheetPresented = $0 },
                    onInteraction: { interactionRequest += 1 },
                    onDismiss: {
                        isExplicitlyDismissing = true
                        playbackEngine.presentedPlayerDocument = nil
                        dismiss()
                    }
                )
            }
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.accessibilityReduceMotion, reduceMotion)
            .environment(\.legibilityWeight, legibilityWeight)
        )
        .ignoresSafeArea(edges: .bottom)
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
                .accessibilityLabel("Minimize Player")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAppearanceSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("Reading Appearance")
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
            readerVisible = true
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
            readerVisible = false
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
    var onSheetPresentationChanged: (Bool) -> Void
    var onInteraction: () -> Void
    var onDismiss: () -> Void
    @State private var showSpeedSheet = false
    @State private var showVoiceSheet = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isGeneratingAudio: Bool {
        !playbackEngine.isAppleActive && generationManager.generatingDocumentIDs.contains(document.id) &&
            playbackEngine.chunks.isEmpty && document.audioFileURL == nil
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let min = Int(time) / 60
        let sec = Int(time) % 60
        return String(format: "%02d:%02d", min, sec)
    }
    
    var body: some View {
        VStack(spacing: 4) {
            if verticalSizeClass == .compact {
                HStack(spacing: 16) {
                    playbackTime
                    timeline
                }
            } else {
                timeline
                HStack {
                    queueButton
                    Spacer()
                    playbackTime
                    Spacer()
                    stopButton
                }
            }

            // Bottom Row
            HStack(spacing: 0) {
                if verticalSizeClass == .compact {
                    queueButton
                    Spacer()
                }
                // Speed Button
                Button(action: {
                    onInteraction()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSheetPresentationChanged(true)
                    showSpeedSheet = true
                }) {
                    Text(String(format: "%.1fx", playbackEngine.playbackRate))
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Reading Speed")
                .accessibilityValue(String(format: "%.1f times", playbackEngine.playbackRate))
                
                Spacer()
                
                let interval = UserDefaults.standard.integer(forKey: "defaultSkipInterval")
                let skipVal = interval == 0 ? 15 : interval
                
                Button(action: { 
                    onInteraction()
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
                .accessibilityLabel("Skip Back \(skipVal) Seconds")
                
                Spacer()
                
                Button(action: {
                    onInteraction()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let isGenerating = !playbackEngine.isAppleActive && generationManager.generatingDocumentIDs.contains(document.id) && playbackEngine.chunks.isEmpty && document.audioFileURL == nil
                    
                    if isGenerating {
                        generationManager.cancelCurrentGeneration()
                        playbackEngine.pause()
                    } else if !playbackEngine.isAppleActive && playbackEngine.chunks.isEmpty && document.audioFileURL == nil && !generationManager.generatingDocumentIDs.contains(document.id) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            let resumeIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? document.lastReadCharIndex
                            if resumeIndex > 0 {
                                playbackEngine.seek(toCharIndex: resumeIndex)
                                playbackEngine.play()
                            } else {
                                generationManager.generate(document: document, playbackEngine: playbackEngine)
                                playbackEngine.play()
                            }
                        }
                    } else {
                        playbackEngine.togglePlayPause()
                    }
                }) {
                    let isGenerating = !playbackEngine.isAppleActive && generationManager.generatingDocumentIDs.contains(document.id) && playbackEngine.chunks.isEmpty && document.audioFileURL == nil
                    let showPauseIcon = playbackEngine.isPlaying || isGenerating
                    
                    Image(systemName: showPauseIcon ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(DesignSystem.accent)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .overlay(
                            Group {
                                if isGenerating {
                                    SpinnerOverlay(isGenerating: isGenerating)
                                        .transition(.opacity)
                                        .allowsHitTesting(false)
                                }
                            }
                        )
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(isGeneratingAudio ? "Cancel Audio Generation" : playbackEngine.isPlaying ? "Pause Playback" : "Play")
                
                Spacer()
                
                Button(action: { 
                    onInteraction()
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
                .accessibilityLabel("Skip Forward \(skipVal) Seconds")
                
                Spacer()
                
                // Voice Button
                Button(action: {
                    onInteraction()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSheetPresentationChanged(true)
                    showVoiceSheet = true
                }) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Choose Voice")
                if verticalSizeClass == .compact {
                    Spacer()
                    stopButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16) 
        .padding(.top, 4)
        .contentShape(Rectangle()) // Capture all taps so they don't fall through to text!
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)

        .onChange(of: showSpeedSheet || showVoiceSheet) { _, presented in
            onSheetPresentationChanged(presented)
        }
        .onDisappear { onSheetPresentationChanged(false) }
        .sheet(isPresented: $showSpeedSheet) {
            SpeedSettingsView()
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSelectionSheetView(document: document, playbackEngine: playbackEngine)
        }
    }

    private var timeline: some View {
        LiveEdgeScrubber(
            currentTime: $progress.currentTime,
            generatedDuration: playbackEngine.duration,
            estimatedDuration: document.estimatedDuration,
            isFullyGenerated: document.audioFileURL != nil,
            onInteraction: onInteraction,
            onSeek: { playbackEngine.seek(to: $0) }
        )
    }

    private var playbackTime: some View {
        let speed = Double(playbackEngine.playbackRate)
        let current = formatTime(progress.currentTime / speed)
        let total = document.audioFileURL != nil ? formatTime(playbackEngine.duration / speed) : "~\(formatTime(document.estimatedDuration / speed))"
        return Text("\(current) / \(total)")
            .font(.caption2.monospacedDigit())
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
    }

    private var queueButton: some View {
        Button {
            onInteraction()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showQueueSheet = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("Up Next")
    }

    private var stopButton: some View {
        Button {
            onInteraction()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playbackEngine.pause()
            if generationManager.generatingDocumentIDs.contains(document.id) {
                generationManager.cancelCurrentGeneration()
            }
            playbackEngine.clearMemory()
            playbackEngine.currentDocument = nil
            onDismiss()
        } label: {
            Image(systemName: "stop.fill")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("Stop Playback and Close Player")
    }

}

struct ScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1.0)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.2, dampingFraction: 0.5, blendDuration: 0.5), value: configuration.isPressed)
    }
}

struct LiveEdgeScrubber: View {
    @Binding var currentTime: TimeInterval
    let generatedDuration: TimeInterval
    let estimatedDuration: TimeInterval
    let isFullyGenerated: Bool
    let onInteraction: () -> Void
    let onSeek: (TimeInterval) -> Void
    @State private var dragTime: TimeInterval?

    private var totalTime: TimeInterval {
        let total = isFullyGenerated ? generatedDuration : estimatedDuration
        return total.isFinite ? max(0, total) : 0
    }

    private func positionLabel(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time.isFinite ? time : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        GeometryReader { geometry in
            let validTotal = max(1, totalTime)
            let displayTime = dragTime ?? currentTime
            let progressRatio = CGFloat(max(0, min(1, displayTime / validTotal)))
            let bufferRatio = isFullyGenerated ? 1 : CGFloat(max(0, min(1, generatedDuration / validTotal)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: geometry.size.width * bufferRatio, height: 3)
                Capsule()
                    .fill(DesignSystem.accent)
                    .frame(width: geometry.size.width * progressRatio, height: 3)
                Circle()
                    .fill(DesignSystem.accent)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(geometry.size.width - 10, geometry.size.width * progressRatio - 5)))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onInteraction()
                        let fraction = max(0, min(1, value.location.x / max(1, geometry.size.width)))
                        dragTime = fraction * totalTime
                    }
                    .onEnded { _ in
                        onInteraction()
                        if let dragTime { onSeek(dragTime) }
                        dragTime = nil
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue("\(positionLabel(currentTime)) of \(isFullyGenerated ? "" : "approximately ")\(positionLabel(totalTime))")
        .accessibilityAdjustableAction { direction in
            let target: TimeInterval
            switch direction {
            case .increment: target = min(totalTime, currentTime + 15)
            case .decrement: target = max(0, currentTime - 15)
            @unknown default: return
            }
            onInteraction()
            onSeek(target)
        }
        .accessibilityHint("Adjusts playback by 15 seconds")
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
        .presentationBackgroundInteraction(.disabled)
    }
}


struct SpinnerState {
    var trimEnd: CGFloat = 0.01
    var trimStart: CGFloat = 0.0
}

struct SpinnerOverlay: View {
    let isGenerating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        if reduceMotion {
            Circle()
                .stroke(DesignSystem.accent.opacity(0.6), lineWidth: 3)
                .frame(width: 60, height: 60)
                .opacity(isGenerating ? 1 : 0)
                .accessibilityHidden(true)
        } else {
        KeyframeAnimator(
            initialValue: SpinnerState(),
            repeating: isGenerating
        ) { state in
            Circle()
                .trim(from: state.trimStart, to: state.trimEnd)
                .stroke(
                    DesignSystem.accent,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 60, height: 60)
        } keyframes: { _ in
            // Lead point — races ahead, finishes at 3 o'clock
            KeyframeTrack(\.trimEnd) {
                CubicKeyframe(0.75, duration: 0.6)   // Head start: 0→75%
                CubicKeyframe(1.0, duration: 0.4)    // Lead finishes: 75→100%
                CubicKeyframe(1.0, duration: 0.5)    // Holds at finish line
                CubicKeyframe(0.01, duration: 0.01)  // Reset (instant)
            }
            
            // Tail point — follows behind, sprints to catch up
            KeyframeTrack(\.trimStart) {
                CubicKeyframe(0.25, duration: 0.6)   // Running behind: 0→25%
                CubicKeyframe(0.45, duration: 0.4)   // Still running: 25→45%
                SpringKeyframe(0.98, duration: 0.5, spring: .init(response: 0.4, dampingRatio: 0.75)) // SPRINT! Springs to finish
                CubicKeyframe(0.0, duration: 0.01)   // Reset (instant)
            }
        }
        .opacity(isGenerating ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isGenerating)
        .accessibilityHidden(true)
        }
    }
}


private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
