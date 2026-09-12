import Combine
import Foundation

/// App-to-app calls. Type & Speak synthesizes on the sender's device and
/// injects into the outgoing track. Also handles answering incoming calls
/// via `answerIncoming` — see that method for how it differs from
/// outgoing `start`.
///
/// RTM is kept, but demoted: it now only carries the plain text as a
/// non-blocking transcript feed for the receiver's on-screen captions (an
/// EchoSign-to-EchoSign receiver can show exact text instead of relying on
/// speech recognition against synthesized audio). RTM is never on the
/// audio or control path — a dropped RTM message degrades captions, never
/// the call.
final class VoIPCallEngine: CallEngine {

    let typeAndSpeak: TypeAndSpeakController

    private let agora: AgoraService
    private let callKit: CallKitManager
    private let rtm: AgoraRtmService
    private let signaling: CallSignalingClient

    private let eventSubject = PassthroughSubject<CallEngineEvent, Never>()
    var eventPublisher: AnyPublisher<CallEngineEvent, Never> { eventSubject.eraseToAnyPublisher() }

    private var callId: String?
    private let duckCoordinator: MicDuckCoordinator
    private var isSpeakerOn = true

    init(agora: AgoraService, callKit: CallKitManager, rtm: AgoraRtmService, signaling: CallSignalingClient) {
        self.agora = agora
        self.callKit = callKit
        self.rtm = rtm
        self.signaling = signaling
        self.duckCoordinator = MicDuckCoordinator(agora: agora)
        self.typeAndSpeak = TypeAndSpeakController(sink: AgoraPushSink(agora: agora, duckCoordinator: duckCoordinator))

        // Best-effort caption feed. Deliberately not gated on RTM delivery
        // succeeding — if it fails, `onError` just logs; the audio already
        // went out over Agora regardless.
        typeAndSpeak.onWordBoundary = { [weak self] _, fullText in
            self?.rtm.send(fullText)
        }
    }

    func start(target: CallTarget) async throws {
        guard case .contact = target else {
            throw EngineError.wrongEngine("VoIPCallEngine received a non-contact target")
        }
        eventSubject.send(.connecting)

        let call = try await signaling.createCall(target: target)
        self.callId = call.callId

        if !call.pushDelivered {
            // Not fatal — the caller can still wait/retry — but worth
            // surfacing so "ringing forever" doesn't look identical to a
            // call that's genuinely reaching the other device.
            print("[VoIP] Push delivery to callee failed — they may not be notified")
        }

        try await joinAgoraAndRTM(
            agoraChannel: call.agoraChannel,
            rtcToken: call.rtcToken,
            rtmToken: call.rtmToken,
            uid: call.uid
        )
        callKit.startCall(channelID: call.agoraChannel)
        callKit.onTeardownMedia = { [weak self] in
            self?.agora.leaveChannel()
        }

        eventSubject.send(.connected)
    }

    /// Answers an incoming call — `CallKitManager.onAnswerCall` fires this
    /// path via whatever coordinates `PushKitManager`'s pending call info
    /// with this engine (see `CallViewModel`/`IncomingCallCoordinator`).
    /// Skips `signaling.createCall` (the caller already did that) and
    /// instead fetches this device's own join token via
    /// `signaling.joinCall`, since the caller's token is scoped to their
    /// own uid, not this device's.
    func answerIncoming(callId: String) async throws {
        eventSubject.send(.connecting)
        self.callId = callId

        let joinInfo = try await signaling.joinCall(callId: callId)
        try await joinAgoraAndRTM(
            agoraChannel: joinInfo.agoraChannel,
            rtcToken: joinInfo.rtcToken,
            rtmToken: joinInfo.rtmToken,
            uid: joinInfo.uid
        )
        // CallKit's incoming-call UUID is already active by this point
        // (set in `CallKitManager.reportIncomingCall`) — no `startCall`
        // needed here, just wire teardown for when this call ends.
        callKit.onTeardownMedia = { [weak self] in
            self?.agora.leaveChannel()
        }
        callKit.reportConnected()

        eventSubject.send(.connected)
    }

    private func joinAgoraAndRTM(agoraChannel: String, rtcToken: String, rtmToken: String, uid: UInt) async throws {
        agora.prepare()
        agora.setPlaybackCaptionsEnabled(true)
        agora.joinChannel(channelName: agoraChannel, token: rtcToken, uid: uid)

        // RTM join is best-effort for captions, not call-critical — a
        // failure here shouldn't fail the whole call.
        do {
            try await rtm.login(userId: String(uid), token: rtmToken)
            try await rtm.joinChannel(agoraChannel)
        } catch {
            print("[VoIP] RTM join failed (non-fatal): \(error)")
        }
    }

    func end() {
        typeAndSpeak.stop()
        rtm.leave()
        // callKit.endCall() triggers CXEndCallAction, which fires
        // onTeardownMedia (wired above) — that's what actually leaves the
        // Agora channel now. Previously this also called
        // agora.leaveChannel() directly here, which double-called it on
        // top of what CallKitManager was already doing internally.
        callKit.endCall()
        if let callId { Task { try? await signaling.endCall(callId: callId) } }
        eventSubject.send(.ended)
    }

    var isMuted: Bool { duckCoordinator.isManuallyMuted }

    func toggleMute() {
        // Routed through the coordinator so this can never be silently
        // overridden by TTS ducking finishing mid-call, and so it doesn't
        // silently override an in-flight duck either — the two reasons to
        // mute are now tracked independently and OR'd together.
        duckCoordinator.setManuallyMuted(!duckCoordinator.isManuallyMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        agora.setSpeakerphone(isSpeakerOn)
    }

    func sendTypedText(_ text: String) {
        typeAndSpeak.speak(text)
    }

    func stopSpeaking() {
        typeAndSpeak.stop()
    }

    enum EngineError: LocalizedError {
        case wrongEngine(String)
        var errorDescription: String? { switch self { case .wrongEngine(let m): return m } }
    }
}
