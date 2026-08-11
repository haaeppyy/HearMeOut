import AVFoundation
import Combine
import Foundation

/// Single source of truth for the call screen. Owns and coordinates
/// `AgoraService`, `CallKitManager`, `CaptionService`, and `TTSService`,
/// translating their events into the `@Published` state the UI binds to.
final class CallViewModel: ObservableObject {

    @Published var callState: CallState = .idle
    @Published var captionLog: [CaptionService.CaptionLine] = []
    @Published var inputText = ""
    @Published var isMuted = false
    @Published var isSpeakerOn = true
    @Published var errorMessage: String?

    @Published private(set) var remoteUid: UInt?

    let channelID: String

    private let agora: AgoraService
    private let callKit: CallKitManager
    private let captions: CaptionService
    private let tts: TTSService
    private var cancellables = Set<AnyCancellable>()

    init(channelID: String) {
        self.channelID = channelID
        agora = AgoraService(appID: Secrets.agoraAppID)
        callKit = CallKitManager(agora: agora)
        captions = CaptionService()
        tts = TTSService(agora: agora)
        wire()
    }

    // MARK: - Public API

    func startCall(channelID: String) {
        guard callState == .idle else { return }
        guard Secrets.hasRealCredentials else {
            errorMessage = "Set your Agora App ID and temp token in Secrets.swift before testing."
            callState = .failed("Missing Agora credentials")
            return
        }

        callState = .connecting

        // Best-effort: pre-request the microphone so Agora doesn't start muted.
        // Never blocks setup — Agora prompts if permission is still pending.
        AVAudioApplication.requestRecordPermission { _ in }

        agora.prepare()
        agora.setPlaybackCaptionsEnabled(true)
        // Join directly instead of waiting on CallKit: the call must work even if
        // the OS rejects CallKit's start transaction (stale calls, resets, etc.).
        agora.joinChannel(channelName: channelID, token: Secrets.agoraTempToken, uid: 0)
        callKit.startCall(channelID: channelID)
    }

    func endCall() {
        guard callState != .idle, callState != .ended else { return }
        tts.stop()
        captions.stop()
        callKit.endCall()
        // `CXEndCallAction` → `AgoraService.leaveChannel` → `didLeaveChannel` → teardown,
        // but make the UI respond immediately too.
        teardown()
    }

    func toggleMute() {
        isMuted.toggle()
        agora.muteLocalAudio(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        agora.setSpeakerphone(isSpeakerOn)
    }

    /// Type & Speak: synthesize `inputText` and inject it into the call audio.
    func sendTypedText() {
        guard callState == .connected else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        tts.speak(text)
        inputText = ""
    }

    // MARK: - Wiring

    private func wire() {
        agora.eventSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] event in self?.handleAgoraEvent(event) }
            .store(in: &cancellables)

        captions.$lines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in self?.captionLog = lines }
            .store(in: &cancellables)

        captions.onError = { [weak self] message in self?.errorMessage = message }
        tts.onError = { [weak self] message in self?.errorMessage = message }
        callKit.onCallEndedByCallKit = { [weak self] in self?.teardown() }
        callKit.onCallKitError = { [weak self] message in
            guard let self else { return }
            if self.errorMessage == nil {
                self.errorMessage = "CallKit error: \(message)"
            }
        }
    }

    // MARK: - Service events

    private func handleAgoraEvent(_ event: AgoraEvent) {
        switch event {
        case .didJoinChannel:
            callKit.reportConnected()

        case .remoteUserJoined(let uid):
            remoteUid = uid
            callState = .connected
            startCaptionsIfNeeded()

        case .remoteUserOffline:
            // Prototype: the call ends when the far side leaves.
            callKit.endCall()
            teardown()

        case .didLeaveChannel:
            teardown()

        case .connectionStateChanged(let state, let reason):
            switch state {
            case .failed:
                print("[Echo] connection failed, reason raw \(reason.rawValue)")
                callKit.reportCallFailed()
                if errorMessage == nil {
                    errorMessage = "Couldn't connect to the channel (check your channel ID and temp token)."
                }
                callState = .failed("Couldn't connect to the channel")
            default:
                break
            }
        }
    }

    // MARK: - Internals

    /// Start remote captions only once the far side has joined, so the ~60-second
    /// on-device recognition window isn't spent idle while dialing.
    /// Best-effort: caption prerequisites failing must never knock out the call.
    private func startCaptionsIfNeeded() {
        guard !captions.isListening else { return }
        captions.setSource(.remote)
        Task {
            guard await captions.prepare() else { return }
            captions.start()
        }
    }

    private func teardown() {
        // `.failed` keeps the error alert visible until the user acknowledges it;
        // don't let stray leave/reset events dismiss the screen underneath it.
        if case .failed = callState { return }
        guard callState != .ended, callState != .idle else { return }
        tts.stop()
        captions.stop()
        callState = .ended
    }
}