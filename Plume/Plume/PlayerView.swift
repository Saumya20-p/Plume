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
        
        ZStack {
            activeTheme.backgroundColor.ignoresSafeArea()
            
            ZStack {
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
                .ignoresSafeArea(edges: .bottom)
                
                // Bottom Bar / Overlay for Generation & Playback
                VStack {
                    Spacer()
                    PlayerControlsView(
                        document: document,
                        playbackEngine: playbackEngine,
                        generationManager: generationManager,
                        showQueueSheet: $showQueueSheet
                    )
                    .padding(.bottom, 24)
                }
            }
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
                HStack {
                    Button {
                        showQueueSheet = true
                    } label: {
                        Image(systemName: "text.quote")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    
                    Button {
                        showAppearanceSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
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
            }
            
            if document.audioFileURL != nil {
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
    @State private var showSpeedSheet = false
    
    private func formatTime(_ time: TimeInterval) -> String {
        let min = Int(time) / 60
        let sec = Int(time) % 60
        return String(format: "%02d:%02d", min, sec)
    }
    
    var body: some View {
        // Premium Speechify-like Player always visible
        VStack(spacing: 16) {
            // Top Row
            HStack {
                // Avatar Placeholder
                Image(systemName: "book.pages.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Circle())
                    
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                        
                    if generationManager.generatingDocumentIDs.contains(document.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(generationManager.generationProgress ?? "Preparing Audio...")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else if playbackEngine.chunks.isEmpty && document.audioFileURL == nil {
                        Text("Ready to Play")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    
                    let isFullyGenerated = document.audioFileURL != nil
                    let speed = Double(playbackEngine.playbackRate)
                    
                    if isFullyGenerated {
                        Text("\(formatTime(progress.currentTime / speed)) / \(formatTime(playbackEngine.duration / speed))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(formatTime(progress.currentTime / speed)) / ~\(formatTime(document.estimatedDuration / speed))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    playbackEngine.pause()
                    if generationManager.generatingDocumentIDs.contains(document.id) {
                        generationManager.cancelCurrentGeneration()
                    }
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Stop playback and generation")
            }
            
            LiveEdgeScrubber(
                currentTime: $progress.currentTime,
                generatedDuration: playbackEngine.duration,
                estimatedDuration: document.estimatedDuration,
                isFullyGenerated: document.audioFileURL != nil,
                onSeek: { targetTime in
                    playbackEngine.seek(to: targetTime)
                }
            )
            .padding(.vertical, -4)
            
            // Bottom Row
            HStack(spacing: 0) {
                Button(action: {
                    showSpeedSheet = true
                }) {
                    Text(String(format: "%.1fx", playbackEngine.playbackRate))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Change playback speed")
                
                Spacer()
                
                let interval = UserDefaults.standard.integer(forKey: "defaultSkipInterval")
                let skipVal = interval == 0 ? 15 : interval
                
                Button(action: { playbackEngine.skipBackward() }) {
                    Image(systemName: "gobackward.\(skipVal)")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Skip backward \(skipVal) seconds")
                
                Spacer()
                
                Button(action: {
                    if playbackEngine.chunks.isEmpty && document.audioFileURL == nil && !generationManager.generatingDocumentIDs.contains(document.id) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            generationManager.generate(document: document, playbackEngine: playbackEngine)
                        }
                    } else {
                        playbackEngine.togglePlayPause()
                    }
                }) {
                    Group {
                        if generationManager.generatingDocumentIDs.contains(document.id) && playbackEngine.chunks.isEmpty && document.audioFileURL == nil {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                        }
                    }
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(DesignSystem.accent)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(playbackEngine.isPlaying ? "Pause" : "Play")
                
                Spacer()
                
                Button(action: { playbackEngine.skipForward() }) {
                    Image(systemName: "goforward.\(skipVal)")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Skip forward \(skipVal) seconds")
                
                Spacer()
                
                Button(action: {
                    showQueueSheet = true
                }) {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Open queue")
            }
        }
        .padding()
        .glassmorphic(cornerRadius: DesignSystem.cornerRadiusCard)
        .padding(.horizontal)
        .sheet(isPresented: $showSpeedSheet) {
            SpeedSettingsView()
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
    
    var body: some View {
        GeometryReader { geometry in
            let totalTime = isFullyGenerated ? generatedDuration : estimatedDuration
            let validTotal = totalTime > 0 ? totalTime : 1
            
            let displayTime = dragTime ?? currentTime
            let progressRatio = CGFloat(displayTime / validTotal)
            let bufferRatio = isFullyGenerated ? 1.0 : CGFloat(generatedDuration / validTotal)
            
            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 6)
                
                // Gray Buffer Bar
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: max(0, geometry.size.width * min(1.0, bufferRatio)), height: 6)
                
                // Active Playback Progress
                Capsule()
                    .fill(DesignSystem.accent)
                    .frame(width: max(0, geometry.size.width * min(1.0, progressRatio)), height: 6)
                
                // Playhead Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, geometry.size.width * min(1.0, progressRatio) - 7))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                let targetTime = fraction * validTotal
                                
                                dragTime = targetTime
                            }
                            .onEnded { _ in
                                if let finalTime = dragTime {
                                    onSeek(finalTime)
                                }
                                dragTime = nil
                            }
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = max(0, min(1, location.x / geometry.size.width))
                let targetTime = fraction * validTotal
                
                onSeek(targetTime)
            }
        }
        .frame(height: 24)
    }
}
