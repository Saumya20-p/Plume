import SwiftUI
import AVFoundation
import Observation

// MARK: - Voice Preview Controller

/// Manages non-destructive previews for both Kokoro neural voices and Apple Speech voices.
/// Previews run on an isolated synthesizer / player, ensure the active playback reader is paused
/// without destructive restarts, and cancel cleanly when the view is dismissed or backgrounded.
@Observable
@MainActor
final class VoicePreviewController {
    static let previewSampleText = "Hi, I am ready to read."
    
    private(set) var previewingVoiceID: String?
    private(set) var isGeneratingPreview: Bool = false
    
    @ObservationIgnored private let appleSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var delegateBridge: PreviewDelegateBridge?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    
    init() {
        let bridge = PreviewDelegateBridge { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePlaybackFinished()
            }
        }
        self.delegateBridge = bridge
        self.appleSynthesizer.delegate = bridge
        
        self.backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }
    
    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }
    
    func preview(voiceID: PlaybackVoiceID) {
        let identifier = voiceID.identifier
        
        // Toggle: if already previewing this voice, stop it
        if previewingVoiceID == identifier {
            stop()
            return
        }
        
        stop()
        
        // Non-destructive pause: if reader is active, pause without auto-resuming later
        if AudioPlaybackEngine.shared.isPlaying {
            AudioPlaybackEngine.shared.pause()
        }
        
        // Prepare audio session
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[VoicePreview] Failed to configure audio session: \(error)")
            }
        }
        
        switch voiceID {
        case .apple(let id):
            previewAppleVoice(id: id)
        case .kokoro(let id):
            previewKokoroVoice(id: id)
        }
    }
    
    private func previewAppleVoice(id: String) {
        previewingVoiceID = id
        let utterance = AVSpeechUtterance(string: Self.previewSampleText)
        if let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        appleSynthesizer.speak(utterance)
    }
    
    private func previewKokoroVoice(id: String) {
        previewingVoiceID = id
        
        // 1. Check bundle for pre-rendered previews
        if let bundleURL = Bundle.main.url(forResource: id, withExtension: "m4a") ??
                           Bundle.main.url(forResource: id, withExtension: "m4a", subdirectory: "VoicePreviews") {
            playAudioFile(at: bundleURL)
            return
        }
        
        // 2. Check caches directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePreviews", isDirectory: true)
        let cachedURL = cacheDir.appendingPathComponent("\(id).m4a")
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            playAudioFile(at: cachedURL)
            return
        }
        
        // 3. Check documents directory
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let docURL = docsDir.appendingPathComponent("\(id).m4a")
            if FileManager.default.fileExists(atPath: docURL.path) {
                playAudioFile(at: docURL)
                return
            }
        }
        
        // 4. Generate on first request, cache and reuse
        isGeneratingPreview = true
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try await KokoroTTSService.shared.generatePreview(for: id, outputURL: cachedURL)
                guard !Task.isCancelled, self.previewingVoiceID == id else { return }
                self.isGeneratingPreview = false
                self.playAudioFile(at: cachedURL)
            } catch {
                print("[VoicePreview] Failed to generate preview for \(id): \(error)")
                guard !Task.isCancelled, self.previewingVoiceID == id else { return }
                self.isGeneratingPreview = false
                self.previewingVoiceID = nil
            }
        }
    }
    
    private func playAudioFile(at url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = delegateBridge
            self.audioPlayer = player
            player.play()
        } catch {
            print("[VoicePreview] Failed to play audio file at \(url): \(error)")
            previewingVoiceID = nil
        }
    }
    
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        isGeneratingPreview = false
        
        if appleSynthesizer.isSpeaking {
            appleSynthesizer.stopSpeaking(at: .immediate)
        }
        
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
        }
        audioPlayer = nil
        previewingVoiceID = nil
        
        // Restore playback audio session category
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }
    
    private func handlePlaybackFinished() {
        previewingVoiceID = nil
        isGeneratingPreview = false
    }
}

// MARK: - Preview Delegate Bridge

private final class PreviewDelegateBridge: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable () -> Void
    
    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
        super.init()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onFinish()
    }
}

// MARK: - Voice Settings View

struct VoiceSettingsView: View {
    var document: Document?
    var playbackEngine: AudioPlaybackEngine?
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var preferences: VoicePreferences = VoicePreferencesStore().load()
    @State private var appleCatalog = AppleSpeechVoiceCatalog()
    @State private var previewController = VoicePreviewController()
    
    enum VoiceRoleTab: String, CaseIterable, Identifiable {
        case primary = "Primary Voice"
        case fallback = "Fallback Voice"
        var id: String { rawValue }
    }
    
    @State private var selectedTab: VoiceRoleTab = .primary
    @State private var showRestartConfirmation: Bool = false
    @State private var restartSuccessNotice: Bool = false
    
    private let preferencesStore = VoicePreferencesStore()
    
    init(document: Document? = nil, playbackEngine: AudioPlaybackEngine? = nil) {
        self.document = document
        self.playbackEngine = playbackEngine
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("Voice Category", selection: $selectedTab) {
                ForEach(VoiceRoleTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            List {
                if selectedTab == .primary {
                    primaryVoiceSection
                } else {
                    fallbackVoiceSection
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Voice Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    previewController.stop()
                    dismiss()
                }
            }
        }
        .onDisappear {
            previewController.stop()
        }
        .alert("Restart Current Playback?", isPresented: $showRestartConfirmation) {
            Button("Restart Playback", role: .destructive) {
                restartCurrentPlayback()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Playback restarts from your current reading position with the selected voice.")
        }
    }
    
    // MARK: - Primary Voice Section
    
    @ViewBuilder
    private var primaryVoiceSection: some View {
        // Active session notice
        if activeDocument != nil {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(DesignSystem.accent)
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Playback in Progress")
                                .font(.subheadline.weight(.semibold))
                            Text("This chapter keeps its current voice. Your selection applies to the next chapter.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button {
                        showRestartConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Restart with Selected Voice")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DesignSystem.accent)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
        }
        
        // Unavailable Primary Voice Warning (if previously saved Apple voice was deleted from iOS Settings)
        if case .apple(let savedId) = preferences.primary,
           !appleCatalog.voices.contains(where: { $0.id == savedId }) {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected Voice Unavailable")
                            .font(.subheadline.weight(.semibold))
                        Text("The previously selected Apple voice is no longer installed on this device. Plume will automatically resolve to an available voice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        
        // Kokoro Neural Voices
        ForEach(allVoiceCategories) { category in
            Section(header: Text(category.name)) {
                ForEach(category.voices) { voice in
                    kokoroVoiceRow(voice: voice, categoryName: category.name)
                }
            }
        }
        
        // Apple Speech Voices
        Section(
            header: Text("Apple Speech Voices"),
            footer: Text("Low-latency on-device system voices. Only Enhanced and Premium voices are eligible. Download more in iOS Settings > Accessibility > Spoken Content > Voices.")
        ) {
            if appleCatalog.voices.isEmpty {
                Text("No Enhanced or Premium Apple voices found on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appleCatalog.voices) { descriptor in
                    appleVoiceRow(descriptor: descriptor, isPrimary: true)
                }
            }
        }
    }
    
    // MARK: - Fallback Voice Section
    
    @ViewBuilder
    private var fallbackVoiceSection: some View {
        Section(
            header: Text("Fallback Behavior"),
            footer: Text("Used when your main voice can’t continue. Choose an Enhanced or Premium Apple voice.")
        ) {
            // System Default / Automatic
            Button { selectFallback(nil) } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Default (Automatic)")
                        .font(.body)
                    Text("Automatically uses the device's system English voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if preferences.fallbackAppleVoiceIdentifier == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DesignSystem.accent)
                        .accessibilityLabel("Selected")
                }
            }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select system default fallback voice")
            .accessibilityAddTraits(preferences.fallbackAppleVoiceIdentifier == nil ? .isSelected : [])
        }
        
        // Unavailable Fallback Warning
        if let fallbackId = preferences.fallbackAppleVoiceIdentifier,
           !appleCatalog.voices.contains(where: { $0.id == fallbackId }) {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected Fallback Unavailable")
                            .font(.subheadline.weight(.semibold))
                        Text("The previously selected fallback voice is no longer installed on this device. Plume will automatically use the system default.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        
        Section(header: Text("Eligible Apple Voices")) {
            if appleCatalog.voices.isEmpty {
                Text("No Enhanced or Premium Apple voices found on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appleCatalog.voices) { descriptor in
                    appleVoiceRow(descriptor: descriptor, isPrimary: false)
                }
            }
        }
    }
    
    // MARK: - Row Views
    
    private func kokoroVoiceRow(voice: Voice, categoryName: String) -> some View {
        let selected = preferences.primary == .kokoro(identifier: voice.id)
        return HStack(spacing: 12) {
            Button { selectPrimary(.kokoro(identifier: voice.id)) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.name).font(.body)
                        Text("\(voice.gender) • \(categoryName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(DesignSystem.accent).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(voice.name) as primary voice")
            .accessibilityAddTraits(selected ? .isSelected : [])
            previewButton(for: .kokoro(identifier: voice.id), voiceName: voice.name)
        }
    }
    private func appleVoiceRow(descriptor: AppleSpeechVoiceDescriptor, isPrimary: Bool) -> some View {
        let selected = isPrimary ? preferences.primary == .apple(identifier: descriptor.id) : preferences.fallbackAppleVoiceIdentifier == descriptor.id
        return HStack(spacing: 12) {
            Button {
                if isPrimary { selectPrimary(.apple(identifier: descriptor.id)) }
                else { selectFallback(descriptor.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(descriptor.name).font(.body); qualityBadge(for: descriptor.quality) }
                        Text(appleVoiceSubtitle(for: descriptor)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(DesignSystem.accent).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(descriptor.name) as \(isPrimary ? "primary" : "fallback") voice")
            .accessibilityAddTraits(selected ? .isSelected : [])
            previewButton(for: .apple(identifier: descriptor.id), voiceName: descriptor.name)
        }
    }

    private func previewButton(for voiceID: PlaybackVoiceID, voiceName: String) -> some View {
        let isPreviewing = previewController.previewingVoiceID == voiceID.identifier
        let isGenerating = isPreviewing && previewController.isGeneratingPreview
        
        return Button {
            previewController.preview(voiceID: voiceID)
        } label: {
            Group {
                if isGenerating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .controlSize(.small)
                        .padding(6)
                } else if isPreviewing {
                    Image(systemName: "stop.fill")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(DesignSystem.accent)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.footnote)
                        .foregroundStyle(DesignSystem.accent)
                        .padding(8)
                        .background(DesignSystem.accent.opacity(0.12))
                        .clipShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(isPreviewing ? "Stop preview for \(voiceName)" : "Preview \(voiceName)")
    }
    
    @ViewBuilder
    private func qualityBadge(for quality: AppleSpeechVoiceQuality) -> some View {
        switch quality {
        case .premium:
            Text("Premium")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.purple.opacity(0.15))
                .foregroundStyle(.purple)
                .clipShape(Capsule())
        case .enhanced:
            Text("Enhanced")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        }
    }
    
    // MARK: - Actions
    
    private func selectPrimary(_ voice: PlaybackVoiceID) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        preferences.primary = voice
        preferencesStore.save(preferences)
    }
    
    private func selectFallback(_ identifier: String?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        preferences.fallbackAppleVoiceIdentifier = identifier
        preferencesStore.save(preferences)
    }
    
    private func restartCurrentPlayback() {
        guard let doc = activeDocument else { return }
        let engine = playbackEngine ?? AudioPlaybackEngine.shared
        let charIndex = PlaybackProgress.shared.currentWord?.rangeLocation ?? doc.lastReadCharIndex
        
        previewController.stop()
        AudioGenerationManager.shared.cancelCurrentGeneration()
        engine.clearMemory()
        engine.load(document: doc)
        engine.seek(toCharIndex: charIndex)
        engine.play()
    }
    
    // MARK: - Helpers
    
    private var activeDocument: Document? {
        document ?? playbackEngine?.currentDocument ?? AudioPlaybackEngine.shared.currentDocument
    }
    
    private func appleVoiceSubtitle(for descriptor: AppleSpeechVoiceDescriptor) -> String {
        var parts: [String] = []
        if let voice = AVSpeechSynthesisVoice(identifier: descriptor.id) {
            switch voice.gender {
            case .female:
                parts.append("Female")
            case .male:
                parts.append("Male")
            default:
                break
            }
        }
        parts.append(descriptor.language)
        return parts.joined(separator: " • ")
    }
}
