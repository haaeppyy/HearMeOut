import AVFoundation
import Combine
import Foundation

/// Drives the engine test screen: exercises `CaptionService` (microphone →
/// live transcript) and `TTSService` (text → local speaker playback) with no
/// Agora call involved, so both engines can be validated in isolation.
///
/// Deliberately NOT @MainActor (unlike EchoSign's version): the view
/// constructs it via @StateObject, which requires a nonisolated init.
/// @Published writes already arrive on main (sinks hop via RunLoop.main,
/// TTS callbacks dispatch to main); the one exception is `toggleListening`,
/// whose Task is explicitly @MainActor.
final class EngineTestViewModel: ObservableObject {

    @Published private(set) var transcriptLines: [CaptionService.CaptionLine] = []
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var ttsStatsText = ""

    @Published var ttsInput = ""

    struct VoiceOption: Identifiable, Equatable {
        let id: String
        let name: String
        let qualityLabel: String
        let isPremiumTier: Bool

        var displayName: String {
            isPremiumTier ? "\(name) (\(qualityLabel))" : name
        }
    }

    @Published private(set) var voices: [VoiceOption] = []
    @Published private(set) var voiceHintText: String?
    @Published var selectedVoiceID: String? {
        didSet { tts.voiceIdentifier = selectedVoiceID }
    }

    private let captions = CaptionService()
    private let speakerSink = SpeakerSink()
    private let tts: TTSService
    private var cancellables = Set<AnyCancellable>()

    private var sinkPlayedFrames = 0
    private var sinkRoute = "-"

    init() {
        // The mic source taps AVAudioEngine directly; no Agora session exists here.
        captions.setSource(.local)

        tts = TTSService(sink: speakerSink)

        configureAudioSessionForLocalPlayback()
        captions.onError = { [weak self] message in self?.errorMessage = message }
        captions.$lines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in self?.transcriptLines = lines }
            .store(in: &cancellables)
        captions.$isListening
            .receive(on: RunLoop.main)
            .sink { [weak self] listening in self?.isListening = listening }
            .store(in: &cancellables)

        speakerSink.onError = { [weak self] message in self?.errorMessage = message }
        speakerSink.onStats = { [weak self] playedFrames, route in
            guard let self else { return }
            self.sinkPlayedFrames = playedFrames
            self.sinkRoute = route
            self.refreshTTSStats()
        }

        tts.onError = { [weak self] message in self?.errorMessage = message }
        tts.onCompletion = { [weak self] in self?.statusMessage = "TTS finished" }
        tts.onStats = { [weak self] _ in self?.refreshTTSStats() }
        tts.$isSpeaking
            .receive(on: RunLoop.main)
            .sink { [weak self] speaking in self?.isSpeaking = speaking }
            .store(in: &cancellables)

        refreshTTSStats()
        reloadVoices()
    }

    /// Lists installed English voices, best quality first, and defaults to the
    /// highest tier. Enhanced/Premium voices only exist after the user
    /// downloads them, hence the Settings hint when none are present.
    private func reloadVoices() {
        let qualityRank: [AVSpeechSynthesisVoiceQuality: Int] = [
            .premium: 2, .enhanced: 1, .default: 0
        ]
        let label: [AVSpeechSynthesisVoiceQuality: String] = [
            .premium: "Premium", .enhanced: "Enhanced", .default: "Compact"
        ]

        voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { voice in
                VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    qualityLabel: label[voice.quality] ?? "Compact",
                    isPremiumTier: (qualityRank[voice.quality] ?? 0) > 0
                )
            }
            .sorted {
                if $0.isPremiumTier != $1.isPremiumTier { return $0.isPremiumTier }
                return $0.name < $1.name
            }

        voiceHintText = voices.contains { $0.isPremiumTier }
            ? nil
            : "For much better voices: Settings → Accessibility → Spoken Content → Voices → English — download an Enhanced or Premium voice."

        if selectedVoiceID == nil || !voices.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = bestVoice()?.id
        }
        tts.voiceIdentifier = selectedVoiceID
    }

    private func bestVoice() -> VoiceOption? {
        let rank: (VoiceOption) -> Int = { $0.isPremiumTier ? 1 : 0 }
        return voices.max { rank($0) < rank($1) }
    }

    func toggleListening() {
        errorMessage = nil
        if isListening {
            captions.stop()
            statusMessage = "Stopped listening"
        } else {
            statusMessage = "Preparing speech recognition…"
            Task { @MainActor in
                let ready = await captions.prepare()
                guard ready else {
                    statusMessage = nil
                    return
                }
                captions.start()
                statusMessage = "Listening… speak for over a minute to verify the seamless restart."
            }
        }
    }

    func speakTTS() {
        errorMessage = nil
        let text = ttsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSpeaking else { return }
        statusMessage = "Synthesizing…"
        tts.speak(text)
        ttsInput = ""
    }

    /// A/B control: plain `AVSpeechSynthesizer` playback through the device
    /// speaker. If this is audible but the pipeline isn't, synthesis delivery
    /// is the problem; if neither is audible, the session/route is.
    func speakSanity() {
        errorMessage = nil
        let text = ttsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = "Playing plain synthesized speech…"
        tts.speakDirectly(text.isEmpty ? "This is a plain speech synthesis sanity check." : text)
    }

    // MARK: - Internals

    /// The call baseline uses voice-chat processing, which can silence plain
    /// engine playback. The test screen wants a neutral config.
    private func configureAudioSessionForLocalPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorMessage = "Couldn't configure the audio session: \(error.localizedDescription)"
        }
    }

    private func refreshTTSStats() {
        let stats = tts.snapshotStats()
        ttsStatsText = "cb \(stats.rawCallbacks) · pcm \(stats.pcmBuffers) · "
            + "src \(Self.frameText(stats.sourceFrames)) · out \(Self.frameText(stats.emittedFrames)) · "
            + "played \(Self.frameText(sinkPlayedFrames)) · route: \(sinkRoute)"
    }

    private static func frameText(_ frames: Int) -> String {
        frames >= 10000 ? "\(frames / 1000)k" : "\(frames)"
    }
}
