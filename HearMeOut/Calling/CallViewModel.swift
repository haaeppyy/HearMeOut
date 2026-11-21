import AVFoundation
import Combine
import Foundation

/// Single source of truth for the call screen. Owns and coordinates
/// `AgoraService`, `CallKitManager`, `CaptionService`, and the active
/// `CallEngine`, translating their events into the `@Published` state
/// the UI binds to.
@MainActor
final class CallViewModel: ObservableObject, Identifiable {

    let id = UUID()

    @Published var callState: CallState = .idle
    @Published var captionLog: [CaptionService.CaptionLine] = []

    /// The conversation so far: what was typed and what was heard, in the
    /// order it happened.
    @Published private(set) var transcriptSegments: [TranscriptSegment] = []

    @Published var inputText = ""
    @Published var isMuted = false
    @Published var isSpeakerOn = true
    @Published var errorMessage: String?

    @Published private(set) var remoteUid: UInt?

    /// When the call actually connected. The screens read their timer from
    /// this, so a call that is still ringing does not show a duration that
    /// is quietly counting up from the moment it was placed.
    @Published private(set) var connectedAt: Date?

    /// The backend's id for this call, once it exists.
    @Published private(set) var callId: String?

    // TypeAndSpeakController state — re-subscribed whenever the engine changes.
    @Published var isSpeaking = false
    @Published var highlightedRange: NSRange?
    @Published var spokenText: String = ""

    let otherPartyDisplayName: String

    /// The other party's phone number, when the call was placed from a
    /// contact the app knows.
    var otherPartyPhone: String?

    /// The other party's user id on the server.
    var otherPartyRemoteUserID: String?

    /// Which side this device was on.
    var direction: CallDirection = .outgoing

    /// Which skin the call is on: "audio" or "text". The container sets this
    /// so the history row records how the call was actually made.
    var callMode: String = "audio"

    /// Fired once when the call is over, with everything worth keeping.
    var onCallEnded: ((CallSummary) -> Void)?

    /// Supplies the transcript to save with the call.
    ///
    /// The text skin sets this once the user has said whether they want to
    /// keep the conversation. It is `nil` when there is nothing to save.
    var transcriptProvider: (() -> [TranscriptSegment])?

    /// The conversation store. It is not observable on its own — the view
    /// model publishes its contents.
    private let transcriptStore = TranscriptStore()

    /// The language captions and text-to-speech use.
    ///
    /// English (India) by default; the user's profile picks the rest.
    var language: String = "en-IN"

    private let agora: AgoraService
    private let callKit: CallKitManager
    let captionService: CaptionService
    private let signaling: CallSignalingClient
    private let rtmFactory: () -> AgoraRtmService

    private var engine: CallEngine?
    private var cancellables = Set<AnyCancellable>()
    private var engineCancellables = Set<AnyCancellable>()

    /// When the call was placed.
    private var startedAt: Date?
    /// Guards against emitting the summary twice — the engine's end event and
    /// the user's own "hang up" can both arrive for the same call.
    private var hasFinished = false

    /// Dependency-injected initializer for testing or when the full stack
    /// is assembled externally.
    init(
        otherPartyDisplayName: String,
        agora: AgoraService,
        callKit: CallKitManager,
        captionService: CaptionService,
        signaling: CallSignalingClient,
        rtmFactory: @escaping () -> AgoraRtmService
    ) {
        self.otherPartyDisplayName = otherPartyDisplayName
        self.agora = agora
        self.callKit = callKit
        self.captionService = captionService
        self.signaling = signaling
        self.rtmFactory = rtmFactory
        wire()
    }

    // MARK: - Public API

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

        startedAt = Date()
        connectedAt = nil
        hasFinished = false
        callState = .connecting
        AVAudioApplication.requestRecordPermission { _ in }

        Task {
            do {
                try await engine.start(target: target)
            } catch {
                errorMessage = error.localizedDescription
                callState = .failed(error.localizedDescription)
                finish(outcome: .failed)
            }
        }
    }

    func endCall() {
        guard callState != .idle, callState != .ended else { return }
        engine?.end()
        captionService.stop()
        callState = .ended
        // We hung up. If the call had not connected yet, that is a cancelled
        // call on this side — the callee's side is a missed one, which the
        // server records and the history reconcile picks up.
        finish(outcome: connectedAt == nil ? .cancelled : .completed)
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

        startedAt = Date()
        connectedAt = nil
        hasFinished = false
        direction = .incoming
        callState = .connecting
        AVAudioApplication.requestRecordPermission { _ in }

        Task {
            do {
                try await engine.answerIncoming(callId: callId)
            } catch {
                errorMessage = error.localizedDescription
                callState = .failed(error.localizedDescription)
                finish(outcome: .failed)
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
        transcriptStore.appendTyped(text: text, speaker: .me)
        publishTranscript()
        engine?.sendTypedText(text)
        inputText = ""
    }

    /// Sets the language used for captions and for speech synthesis.
    func setLanguage(_ language: String) {
        self.language = language
        captionService.language = language
        engine?.setLanguage(language)
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
            .sink { [weak self] lines in
                guard let self else { return }
                self.captionLog = lines
                // The captions are the other person's words; they belong in
                // the conversation too.
                self.transcriptStore.updateCaptions(lines)
                self.publishTranscript()
            }
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
        engineCancellables.removeAll()

        // Exact text from the other side, over the data stream.
        engine.textChannel?.onText = { [weak self] text in
            guard let self else { return }
            self.transcriptStore.appendRemoteText(text)
            self.publishTranscript()
        }

        engine.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connecting:
                    self.callState = .connecting
                case .ringing:
                    self.callState = .ringing
                case .connected:
                    self.markConnected()
                case .remoteJoined(let uid):
                    self.remoteUid = uid
                    self.markConnected()
                case .ended:
                    self.callState = .ended
                    // The other side hung up. If it never connected, that is
                    // a missed call on this side.
                    self.finish(outcome: self.connectedAt == nil ? .missed : .completed)
                case .failed(let message):
                    self.callState = .failed(message)
                    self.errorMessage = message
                    self.finish(outcome: .failed)
                }
            }
            .store(in: &engineCancellables)
    }

    // MARK: - Internals

    /// Publishes the conversation after it has changed.
    private func publishTranscript() {
        transcriptSegments = transcriptStore.segments
    }

    private func markConnected() {
        callState = .connected
        if connectedAt == nil {
            connectedAt = Date()
        }
        callId = engine?.callId
        startCaptionsIfNeeded()
    }

    /// Emits the summary for this call, once.
    private func finish(outcome: CallOutcome) {
        guard !hasFinished else { return }
        hasFinished = true
        let now = Date()
        onCallEnded?(CallSummary(
            callId: callId ?? engine?.callId,
            otherPartyDisplayName: otherPartyDisplayName,
            otherPartyPhone: otherPartyPhone,
            otherPartyRemoteUserID: otherPartyRemoteUserID,
            direction: direction,
            callMode: callMode,
            startedAt: startedAt ?? now,
            connectedAt: connectedAt,
            endedAt: now,
            outcome: outcome
        ))
    }

    private func startCaptionsIfNeeded() {
        guard !captionService.isListening else { return }
        captionService.setSource(.remote)
        Task {
            guard await captionService.prepare() else { return }
            captionService.start()
        }
    }
}
