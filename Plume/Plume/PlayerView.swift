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
    @State private var dockHeight: CGFloat = 0
    @State private var wordDisplay = ReaderWordDisplay()
    @ScaledMetric(relativeTo: .subheadline) private var returnPillWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .subheadline) private var returnLineHeight: CGFloat = 20
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearanceManager = AppearanceManager.shared
    
    private var reduceMotion: Bool {
        #if DEBUG
        if UIExperimentFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-reduce-motion") { return true }
        #endif
        return systemReduceMotion
    }

    private var reduceTransparency: Bool {
        #if DEBUG
        if UIExperimentFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-experiment-reduce-transparency") { return true }
        #endif
        return systemReduceTransparency
    }

    var body: some View {
        let activeTheme = appearanceManager.activeTheme(colorScheme: colorScheme)
        
        GeometryReader { geometry in
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
                headerClearance: geometry.safeAreaInsets.top,
                dockHeight: dockHeight,
                reduceTransparency: reduceTransparency,
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
                        Button {
                            isBrowsing = false
                            returnRequest += 1
                        } label: {
                            ZStack {
                                Text(wordDisplay.displayText)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 44)
                                    .frame(maxWidth: .infinity)
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                    .font(.system(size: 17))
                                    .foregroundStyle(DesignSystem.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 16)
                            }
                            .frame(width: min(returnPillWidth, max(44, geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing - 32)), height: max(44, returnLineHeight + 24))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(activeTheme.textColor)
                        .background(activeTheme.backgroundColor.opacity(reduceTransparency ? 1 : 0.8), in: Capsule())
                        .overlay { Capsule().strokeBorder(DesignSystem.accent.opacity(0.4), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .accessibilityLabel("Return to Current Word")
                        .accessibilityValue(wordDisplay.currentWordValue ?? "")
                        .accessibilityHint("Moves the reader to the spoken word")
                        .transaction { $0.animation = nil }
                    }
                    PlayerControlsView(
                        document: document,
                        playbackEngine: playbackEngine,
                        generationManager: generationManager,
                        showQueueSheet: $showQueueSheet,
                        reduceTransparency: reduceTransparency,
                        onSheetPresentationChanged: { controlsSheetPresented = $0 },
                        onInteraction: { interactionRequest += 1 },
                        onDismiss: {
                            isExplicitlyDismissing = true
                            playbackEngine.presentedPlayerDocument = nil
                            dismiss()
                        }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                }
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.legibilityWeight, legibilityWeight)
            )
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .background(activeTheme.backgroundColor.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(reduceTransparency ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(activeTheme.backgroundColor, for: .navigationBar)
        .toolbarColorScheme(activeTheme == .warm ? .light : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(activeTheme.textColor)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    isExplicitlyDismissing = true
                    playbackEngine.presentedPlayerDocument = nil
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .fontWeight(.semibold)
                        .foregroundStyle(activeTheme.textColor)
                }
                .accessibilityLabel("Minimize Player")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAppearanceSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(activeTheme.textColor)
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
                #if DEBUG
                .modifier(UIExperimentEnvironment())
                #endif
        }
        .onChange(of: progress.currentWord, initial: true) { _, _ in updateReturnWord() }
        .onChange(of: playbackEngine.isPlaying) { _, _ in updateReturnWord() }
        .onChange(of: document.id) { _, _ in updateReturnWord() }
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
            
            updateReturnWord()
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

    private func updateReturnWord() {
        let marker = playbackEngine.currentDocument?.id == document.id ? progress.currentWord : nil
        wordDisplay.update(
            word: marker?.word, documentID: document.id, isPaused: !playbackEngine.isPlaying,
            text: document.bodyText, rangeLocation: marker?.rangeLocation,
            savedPosition: playbackEngine.currentDocument?.id == document.id ? document.lastReadCharIndex : nil
        )
    }

}

struct PlayerControlsView: View {
    let document: Document
    @ObservedObject var playbackEngine: AudioPlaybackEngine
    @ObservedObject var progress = PlaybackProgress.shared
    @ObservedObject var generationManager: AudioGenerationManager
    @Binding var showQueueSheet: Bool
    var reduceTransparency: Bool
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
                playbackTime.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
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
                        .font(.caption.bold().monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 44, minHeight: 44)
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
                        .font(.system(size: 17))
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
                    #if DEBUG
                    defer { UIExperimentFixture.recordPlaybackDiagnostics() }
                    #endif
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
                        .font(.system(size: 22))
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
                        .font(.system(size: 17))
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
                        .font(.system(size: 17))
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
        .padding(.bottom, 10)
        .padding(.top, 8)
        .contentShape(Rectangle()) // Capture all taps so they don't fall through to text!
        .background(
            Color(uiColor: .secondarySystemBackground).opacity(reduceTransparency ? 1 : 0.55),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                timeline(dockHeight: geometry.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)

        .onChange(of: showSpeedSheet || showVoiceSheet) { _, presented in
            onSheetPresentationChanged(presented)
        }
        .onDisappear { onSheetPresentationChanged(false) }
        .sheet(isPresented: $showSpeedSheet) {
            SpeedSettingsView()
                #if DEBUG
                .modifier(UIExperimentEnvironment())
                #endif
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSelectionSheetView(document: document, playbackEngine: playbackEngine)
        }
    }

    private func timeline(dockHeight: CGFloat) -> some View {
        LiveEdgeScrubber(
            currentTime: $progress.currentTime,
            dockHeight: dockHeight,
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
            .lineLimit(1)
            .minimumScaleFactor(0.5)
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
                .font(.system(size: 17))
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
            playbackEngine.stopAndRelease()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17))
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
    var dockHeight: CGFloat = 120
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

    private func rim(color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(color, lineWidth: 3)
            .frame(width: width, height: max(48, dockHeight))
            .mask(alignment: .top) { Rectangle().frame(height: 24) }
            .allowsHitTesting(false)
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
            ZStack(alignment: .topLeading) {
                // Draw the very same continuous rounded rectangle as the dock,
                // then expose its upper rim. Horizontal masks preserve seek mapping
                // while carrying progress around both curved ends.
                rim(color: Color.secondary.opacity(0.18), width: geometry.size.width)
                rim(color: Color.secondary.opacity(0.35), width: geometry.size.width)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * bufferRatio) }
                rim(color: DesignSystem.accent, width: geometry.size.width)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * progressRatio) }
                if dragTime != nil {
                    Circle()
                        .fill(DesignSystem.accent)
                        .frame(width: 8, height: 8)
                        .offset(x: max(24, min(geometry.size.width - 24, geometry.size.width * progressRatio)) - 4, y: 0)
                }
            }
            .frame(width: geometry.size.width, height: 44, alignment: .topLeading)
            .contentShape(RimScrubberHitArea())
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

/// Queue and close have 44-point targets starting eight points below the rim.
/// Only the central time label shares the remainder of the scrubber's hit band.
private struct RimScrubberHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 8))
        path.addRect(CGRect(x: rect.minX + 76, y: rect.minY + 8,
                            width: max(0, rect.width - 152), height: max(0, rect.height - 8)))
        return path
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
