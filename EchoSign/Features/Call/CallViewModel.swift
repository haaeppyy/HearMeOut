import AVFoundation
import Combine
import Foundation

/// Single source of truth for the call screen. Owns and coordinates
/// `AgoraService`, `CallKitManager`, `CaptionService`, and the active
/// `CallEngine`, translating their events into the `@Published` state
/// the UI binds to.
@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState: CallState = .idle
    @Published var captionLog: [CaptionService.CaptionLine] = []
    @Published var inputText = ""
    @Published var isMuted = false
    @Published var isSpeakerOn = true
    @Published var errorMessage: String?

    @Published private(set) var remoteUid: UInt?

    // TypeAndSpeakController state — re-subscribed whenever the engine changes.
    @Published var isSpeaking = false
    @Published var highlightedRange: NSRange?
    @Published var spokenText: String = ""

    let channelID: String

    private let agora: AgoraService
    private let callKit: CallKitManager
    let captionService: CaptionService
    private let signaling: CallSignalingClient
    private let rtmFactory: () -> AgoraRtmService

    private var engine: CallEngine?
    private var cancellables = Set<AnyCancellable>()

    init(channelID: String) {
        self.channelID = channelID
        self.agora = AgoraService(appID: Secrets.agoraAppID)
        self.callKit = CallKitManager()
        self.captionService = CaptionService()
        self.signaling = CallSignalingClient(baseURL: Secrets.backendBaseURL) {
            try await Secrets.currentUserAuthToken()
        }
        self.rtmFactory = { AgoraRtmService() }
        wire()
    }

    /// Dependency-injected initializer for testing or when the full stack
    /// is assembled externally.
    init(
        channelID: String,
        agora: AgoraService,
        callKit: CallKitManager,
        captionService: CaptionService,
        signaling: CallSignalingClient,
        rtmFactory: @escaping () -> AgoraRtmService
    ) {
        self.channelID = channelID
        self.agora = agora
        self.callKit = callKit
        self.captionService = captionService
        self.signaling = signaling
        self.rtmFactory = rtmFactory
        wire()
    }

    // MARK: - Public API

    func startCall(channelID: String) {
        startCall(target: .contact(id: channelID, displayName: channelID))
    }

    func startCall(target: CallTarget) {
        guard callState == .idle else { return }

        let engine: CallEngine
        switch target {
        case .contact:
            engine = VoIPCallEngine(
                agora: agora,
                callKit: callKit,
                rtm: rtmFactory(),
                signaling: signaling
            )
        }
        self.engine = engine
        subscribe(to: engine)
        subscribe(toTypeAndSpeak: engine.typeAndSpeak)

        callState = .connecting
        AVAudioApplication.requestRecordPermission { _ in }

        Task {
            do {
                try await engine.start(target: target)
            } catch {
                errorMessage = error.localizedDescription
                callState = .failed(error.localizedDescription)
            }
        }
    }

    func endCall() {
        guard callState != .idle, callState != .ended else { return }
        engine?.end()
        captionService.stop()
        callState = .ended
    }

    /// Answers an incoming call — called by `AppCallCoordinator` once the
    /// user answers from the native CallKit UI. Skips straight to
    /// `VoIPCallEngine.answerIncoming`, bypassing `startCall`'s
    /// `signaling.createCall` since the caller already created the call;
    /// this device just needs its own join token.
    func answerIncomingCall(callId: String) {
        guard callState == .idle else { return }

        let engine = VoIPCallEngine(agora: agora, callKit: callKit, rtm: rtmFactory(), signaling: signaling)
        self.engine = engine
        subscribe(to: engine)
        subscribe(toTypeAndSpeak: engine.typeAndSpeak)

        callState = .connecting
        AVAudioApplication.requestRecordPermission { _ in }

        Task {
            do {
                try await engine.answerIncoming(callId: callId)
            } catch {
                errorMessage = error.localizedDescription
                callState = .failed(error.localizedDescription)
            }
        }
    }

    func toggleMute() {
        engine?.toggleMute()
        // Read back rather than blindly flip — `isMuted` here previously
        // tracked itself independently of what the engine actually did,
        // which could silently drift (e.g. TTS ducking ending mid-call
        // would leave this stale). The engine's MicDuckCoordinator is now
        // the single source of truth.
        isMuted = engine?.isMuted ?? isMuted
    }

    func toggleSpeaker() {
        engine?.toggleSpeaker()
        isSpeakerOn.toggle()
    }

    /// Both engines now handle this identically — sender-side synthesis,
    /// injected into the outgoing track.
    func sendTypedText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, callState == .connected else { return }
        engine?.sendTypedText(text)
        inputText = ""
    }

    /// The pause/stop button the View exposes next to the highlighted text.
    /// Authoritative — nothing already queued past this call reaches the
    /// far end, regardless of which engine is active.
    func stopSpeaking() {
        engine?.stopSpeaking()
    }

    // MARK: - Wiring

    private func wire() {
        agora.onPlaybackPCM = { [weak self] pointer, samplesPerChannel, channels in
            self?.captionService.appendRemotePCM(
                pointer: pointer,
                samplesPerChannel: samplesPerChannel,
                channels: channels
            )
        }

        captionService.$lines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in self?.captionLog = lines }
            .store(in: &cancellables)

        captionService.onError = { [weak self] message in self?.errorMessage = message }
        // Deliberately NOT wiring callKit.onCallEndedByCallKit here anymore
        // — when this CallViewModel is constructed via AppCallCoordinator
        // (the production path), the coordinator is the single owner of
        // that closure, since it also has to notify PushKitManager for
        // calls that were declined before ever reaching a CallViewModel.
        // A standalone CallViewModel (tests, EngineTestView) won't get
        // "CallKit-ended -> endCall()" for free — wire it manually in that
        // context if needed.
        callKit.onCallKitError = { [weak self] message in
            guard let self else { return }
            if self.errorMessage == nil {
                self.errorMessage = "CallKit error: \(message)"
            }
        }
    }

    // MARK: - Engine subscriptions

    private func subscribe(toTypeAndSpeak controller: TypeAndSpeakController) {
        controller.$isSpeaking.receive(on: DispatchQueue.main).assign(to: &$isSpeaking)
        controller.$highlightedRange.receive(on: DispatchQueue.main).assign(to: &$highlightedRange)
        controller.$currentText.receive(on: DispatchQueue.main).assign(to: &$spokenText)
    }

    private func subscribe(to engine: CallEngine) {
        cancellables.removeAll()
        engine.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connecting:
                    self.callState = .connecting
                case .connected, .remoteJoined:
                    self.callState = .connected
                    self.startCaptionsIfNeeded()
                case .ended:
                    self.callState = .ended
                case .failed(let message):
                    self.callState = .failed(message)
                    self.errorMessage = message
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Internals

    private func startCaptionsIfNeeded() {
        guard !captionService.isListening else { return }
        captionService.setSource(.remote)
        Task {
            guard await captionService.prepare() else { return }
            captionService.start()
        }
    }
}
