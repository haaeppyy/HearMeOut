import Combine
import Foundation

/// Orchestrates the full backend calling flow: API calls, CallKit actions,
/// PushKit payloads, Agora sessions, presentation requests and history sync.
/// CallsView stays thin — it renders `audioRequest`/`textRequest` covers and
/// merges history; all async backend work lives here.
@MainActor
final class CallCoordinator: ObservableObject {
    struct CallRequest: Identifiable {
        let id = UUID()
        let contactName: String
        let contact: Contact?
    }

    struct IncomingText: Identifiable {
        let id = UUID()
        let channel: String
        let text: String
        let publisher: String
    }

    let auth: SupabaseAuthManager
    let api: CallAPIClient
    let active: ActiveCall
    /// Protocol-typed (CallKitDriving / PushKitDriving / AgoraDriving) so
    /// tests inject scriptable fakes; production passes the concrete
    /// managers, which already conform. See the three *Driving.swift files.
    let callKit: any CallKitDriving
    let pushKit: any PushKitDriving
    let agora: any AgoraDriving

    /// Speech plane (EchoSign port): live captions of the remote party +
    /// Type & Speak synthesis injected into the outgoing call audio.
    let captions = CaptionService()
    let duck: MicDuckCoordinator
    let typeAndSpeak: TypeAndSpeakController

    /// Caption lines mirrored for SwiftUI (CaptionService publishes them;
    /// this assign bridge keeps views observing one object).
    @Published var captionLines: [CaptionService.CaptionLine] = []

    /// Presentation requests observed by CallsView's fullScreenCovers.
    @Published var audioRequest: CallRequest?
    @Published var textRequest: CallRequest?
    /// RTM texts received during a call, filtered by channel in the view.
    @Published var incomingTexts: [IncomingText] = []
    /// User-facing error/notice banner text.
    @Published var alertMessage: String?

    private struct OutgoingContext {
        let calleeId: String
        let contact: Contact
        let mode: String
    }

    private var pendingOutgoing: [UUID: OutgoingContext] = [:]
    private var pendingMode = "Text Mode"
    private var isFinalizing = false
    private var lastRegisteredPushToken: String?
    private var didActivate = false
    private var cancellables = Set<AnyCancellable>()

    /// Published when a lazy lookup links a contact mid-dial so the UI can
    /// persist it. Observed via onChange (a stored closure would capture a
    /// stale view-struct copy and never reach @State).
    struct LinkedContact: Equatable {
        let localID: UUID
        let remoteID: String
        let nonce = UUID()
    }

    @Published var linkedContact: LinkedContact?

    /// Nonisolated so HearMeOutApp.init can build the graph. No actor state
    /// is touched here — activate() does the wiring on the main actor.
    /// Production entry: concrete managers + an api bound to auth's token.
    nonisolated convenience init(
        auth: SupabaseAuthManager,
        active: ActiveCall,
        callKit: CallKitManager,
        pushKit: PushKitManager,
        agora: AgoraCallManager
    ) {
        self.init(
            auth: auth, active: active,
            callKit: callKit as any CallKitDriving,
            pushKit: pushKit as any PushKitDriving,
            agora: agora as any AgoraDriving,
            // Capture auth weakly: the client outlives nothing, but the closure
            // escapes into URLSession tasks.
            api: CallAPIClient(tokenProvider: { [weak auth] in
                guard let auth else { throw CallAPIError.unauthorized }
                return try await auth.accessToken()
            })
        )
    }

    /// Test entry (internal, visible via @testable): all collaborators
    /// injected, so CallCoordinatorTests drives the real orchestration
    /// against fakes + MockURLProtocol with zero system frameworks.
    nonisolated init(
        auth: SupabaseAuthManager,
        active: ActiveCall,
        callKit: any CallKitDriving,
        pushKit: any PushKitDriving,
        agora: any AgoraDriving,
        api: CallAPIClient
    ) {
        self.auth = auth
        self.active = active
        self.callKit = callKit
        self.pushKit = pushKit
        self.agora = agora
        self.api = api
        self.duck = MicDuckCoordinator(agora: agora)
        self.typeAndSpeak = TypeAndSpeakController(sink: AgoraPushSink(agora: agora))
    }

    /// One-time wiring. Called from the root view's .task (MainActor) right
    /// after the graph is built — NOT from init, which is nonisolated and
    /// cannot touch other actors' state. Idempotent.
    func activate() {
        guard !didActivate else { return }
        didActivate = true
        auth.restore()
        wireCallbacks()
        startPushKit()
    }

    // MARK: - wiring

    private func wireCallbacks() {
        callKit.onAnswer = { [weak self] uuid in
            guard let self else { return }
            await self.answerCall(uuid: uuid)
        }
        callKit.onEnd = { [weak self] uuid in
            guard let self else { return }
            await self.systemEnded(uuid: uuid)
        }
        callKit.onMuteChanged = { [weak self] uuid, muted in
            Task { @MainActor [weak self] in self?.setMuted(muted) }
        }
        callKit.onStartCall = { [weak self] uuid in await self?.performOutgoing(uuid: uuid) ?? false }
        pushKit.onIncomingPush = { [weak self] push, completion in
            Task { @MainActor [weak self] in
                self?.handleIncomingPush(push, completion: completion)
            }
        }
        agora.onMessageReceived = { [weak self] channel, text, publisher in
            Task { @MainActor [weak self] in
                self?.incomingTexts.append(IncomingText(channel: channel, text: text, publisher: publisher))
            }
        }
        // Speech plane: Agora's playback frames are the ONLY audio feed for
        // the `.remote` caption source. Capture the service directly — the
        // closure runs on the audio thread and must not touch actor state.
        let captionService = self.captions
        agora.onPlaybackPCM = { [weak captionService] pointer, samplesPerChannel, channels in
            captionService?.appendRemotePCM(
                pointer: pointer,
                samplesPerChannel: samplesPerChannel,
                channels: channels
            )
        }
        captions.$lines
            .receive(on: DispatchQueue.main)
            .assign(to: &$captionLines)
        captions.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                if self?.alertMessage == nil { self?.alertMessage = message }
            }
        }
        // Start remote captions once the far side joins, so the ~60-second
        // on-device recognition window isn't spent idle while dialing.
        // Best-effort: caption failures must never knock out the call.
        agora.remoteUserJoinedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] joined in
                guard joined else { return }
                Task { @MainActor [weak self] in self?.startCaptions() }
            }
            .store(in: &cancellables)
        // Token changes arrive before/after auth in any order; registration
        // itself gates on configured + authenticated.
        pushKit.voipTokenPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token in
                Task { @MainActor [weak self] in self?.registerPushTokenIfNeeded(token) }
            }
            .store(in: &cancellables)
    }

    func startPushKit() {
        pushKit.start()
    }

    // MARK: - outgoing (UI entry)

    /// Guard chain before any backend work: configured? signed in? contact
    /// linked? Only then touch CallKit. Anything failing here is a local
    /// alert, not a call.
    func startOutgoing(to contact: Contact, mode: String) {
        guard AppConfig.isBackendConfigured, auth.isAuthenticated else {
            alertMessage = "Sign in to place real calls."
            return
        }
        guard !active.isLive else {
            alertMessage = "You're already on a call."
            return
        }
        pendingMode = mode
        active.configureOutgoing(contactName: contact.name, contact: contact)
        let uuid = active.callUUID
        Task {
            // Lazy linkage: contacts saved before users-lookup existed (or
            // while offline) get resolved on first dial.
            var calleeId = contact.remoteUserID
            if calleeId?.isEmpty != false {
                if let hit = await resolveContact(phone: contact.phoneNumber) {
                    calleeId = hit.id
                    linkedContact = LinkedContact(localID: contact.id, remoteID: hit.id)
                }
            }
            guard let calleeId, !calleeId.isEmpty else {
                alertMessage = "\(contact.name) hasn't joined Hear Me Out yet."
                active.reset()
                return
            }
            pendingOutgoing[uuid] = OutgoingContext(calleeId: calleeId, contact: contact, mode: mode)
            callKit.requestOutgoing(contactName: contact.name, uuid: uuid)
        }
    }

    /// Runs inside provider(_:perform: CXStartCallAction). True = fulfill.
    private func performOutgoing(uuid: UUID) async -> Bool {
        guard let context = pendingOutgoing.removeValue(forKey: uuid) else { return false }
        do {
            let response = try await api.startCall(calleeId: context.calleeId)
            callKit.bind(callId: response.callId, to: uuid)
            active.started(
                callId: response.callId,
                channel: response.agoraChannel,
                uid: response.uid,
                pushDelivered: response.pushDelivered
            )
            try await joinMedia(channel: response.agoraChannel, rtcToken: response.rtcToken, rtmToken: response.rtmToken, uid: response.uid)
            active.markActive()
            present(mode: context.mode)
            if !response.pushDelivered {
                alertMessage = "Ringing, but \(context.contact.name)'s phone may not ring (push not delivered)."
            }
            return true
        } catch {
            active.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: - incoming

    /// Called from the PushKit path with the push completion chained behind
    /// CallKit's own report completion — the OS must see the reported call
    /// before we signal done. No awaits run before reportIncoming.
    private func handleIncomingPush(_ push: PushKitManager.IncomingPush, completion: @escaping () -> Void) {
        guard !active.isLive else {
            // Busy: decline politely so the caller gets `missed`, not a
            // second ringing line we can't present.
            Task { try? await api.endCall(callId: push.callId) }
            completion()
            return
        }
        active.configureIncoming(callId: push.callId, channel: push.channelName, contactName: push.callerName)
        callKit.reportIncoming(callId: push.callId, callerName: push.callerName, uuid: active.callUUID) { _ in
            completion()
        }
    }

    private func answerCall(uuid: UUID) async {
        guard let callId = callKit.callId(forUUID: uuid), callId == active.callId else { return }
        do {
            let response = try await api.joinCall(callId: callId)
            active.joined(channel: response.agoraChannel, uid: response.uid)
            try await joinMedia(channel: response.agoraChannel, rtcToken: response.rtcToken, rtmToken: response.rtmToken, uid: response.uid)
            active.markActive()
            let mode = UserDefaults.standard.string(forKey: "defaultCallingInterface") ?? "Text Mode"
            present(mode: mode)
        } catch {
            active.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            callKit.forgetCall(uuid: uuid)
        }
    }

    // MARK: - speech plane (captions + Type & Speak)

    /// Unified mute: stream mute (CallKit-visible, existing path) AND capture
    /// ducking (protects the TTS interplay — see MicDuckCoordinator).
    /// Every mute entry point must drive both; unmute clears both.
    func setMuted(_ muted: Bool) {
        agora.setMuted(muted)
        duck.setManuallyMuted(muted)
    }

    private func startCaptions() {
        guard active.isLive, !captions.isListening else { return }
        captions.setSource(.remote)
        Task {
            guard await captions.prepare() else { return }
            // prepare() is async and the call may have ended while
            // permissions resolved — re-check before starting.
            guard active.isLive else { return }
            agora.setPlaybackCaptionsEnabled(true)
            captions.start()
        }
    }

    /// Type & Speak: synthesize `text` into the outgoing call audio AND
    /// publish it over RTM as the read-backup (receiver-side captions).
    /// Resolves on RTM ack — callers append to sent history on success.
    /// TTS synthesis itself is fire-and-forget best-effort (its errors print;
    /// the text message must not fail with it).
    func speakAndSend(_ text: String) async throws {
        guard let channel = active.channel else { throw CallAPIError.backendNotConfigured }
        typeAndSpeak.speak(text)
        try await agora.sendMessage(text, channel: channel)
    }

    // MARK: - media + presentation

    /// Both RTC and RTM stay joined for the whole call so the in-call
    /// audio/text toggle never tears down a session — only the UI swaps.
    private func joinMedia(channel: String, rtcToken: String, rtmToken: String, uid: Int) async throws {
        try await agora.joinAudio(channel: channel, token: rtcToken, uid: UInt(max(0, uid)))
        do {
            try await agora.joinMessaging(channel: channel, token: rtmToken, rtcUid: uid)
        } catch {
            // Text mode degrades to local-only; audio must not fail with it.
            print("RTM join failed (audio continues): \(error)")
        }
    }

    private func present(mode: String) {
        if mode == "Audio Mode" {
            audioRequest = CallRequest(contactName: active.contactName, contact: active.contact)
        } else {
            textRequest = CallRequest(contactName: active.contactName, contact: active.contact)
        }
    }

    // MARK: - ending

    /// In-app end buttons funnel here with the call's local artifacts.
    func finishAudioCall(recordingDuration: TimeInterval?) {
        Task { await finalize(mode: "audio", transcript: [], didConnect: active.connectedAt != nil, recordingDuration: recordingDuration) }
    }

    func finishTextCall(transcript: [String], didConnect: Bool) {
        Task { await finalize(mode: "text", transcript: transcript, didConnect: didConnect, recordingDuration: nil) }
    }

    /// System end button (CallKit UI / lock screen). The CXEndCallAction is
    /// fulfilled by CallKitManager after this returns.
    private func systemEnded(uuid _: UUID) async {
        await finalize(mode: pendingMode, transcript: collectedTranscript(), didConnect: active.connectedAt != nil, recordingDuration: nil)
    }

    /// UI end buttons that go through CallKit first (keeps the system call
    /// log consistent): request the end, finalization happens in systemEnded.
    func endViaSystem() {
        callKit.requestEnd(uuid: active.callUUID)
    }

    private func finalize(mode: String, transcript: [String], didConnect: Bool, recordingDuration: TimeInterval?) async {
        guard !isFinalizing else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        // Speech plane teardown first: stop synthesis and captions so no
        // callbacks fire into a half-torn-down call.
        typeAndSpeak.stop()
        captions.stop()
        agora.setPlaybackCaptionsEnabled(false)
        let callId = active.callId
        let status: String
        if let callId {
            do {
                status = try await api.endCall(callId: callId).status
            } catch {
                status = "ended"
                print("endCall failed (best effort): \(error)")
            }
        } else {
            status = "ended"
        }
        agora.leaveAll()
        let finished = FinishedCall(
            contactName: active.contactName,
            contact: active.contact,
            mode: mode,
            startedAt: active.connectedAt ?? Date(),
            transcript: transcript,
            didConnect: didConnect,
            callId: callId,
            serverStatus: status,
            recordingDuration: recordingDuration
        )
        active.end(status: status)
        audioRequest = nil
        textRequest = nil
        incomingTexts.removeAll()
        finishedCall = finished
    }

    /// Local record handed to CallsView for history persistence.
    struct FinishedCall: Equatable {
        let contactName: String
        let contact: Contact?
        let mode: String
        let startedAt: Date
        let transcript: [String]
        let didConnect: Bool
        let callId: String?
        let serverStatus: String
        let recordingDuration: TimeInterval?
    }

    @Published var finishedCall: FinishedCall?

    private func collectedTranscript() -> [String] {
        guard let channel = active.channel else { return [] }
        return incomingTexts.filter { $0.channel == channel }.map(\.text)
    }

    // MARK: - push token

    /// Call after auth is established and whenever the VoIP token changes.
    /// Best effort: a missing token only means no incoming rings.
    func registerPushTokenIfNeeded(_ token: String?) {
        guard let token, !token.isEmpty, token != lastRegisteredPushToken else { return }
        guard AppConfig.isBackendConfigured, auth.isAuthenticated else { return }
        lastRegisteredPushToken = token
        Task {
            do { try await api.registerPushToken(token) }
            catch { print("push-token registration failed (best effort): \(error)") }
        }
    }

    // MARK: - contacts + history (Phases 7-8)

    /// Resolve a phone number to a registered user. Returns nil (not throws)
    /// when nobody matches — the UI shows "not on Hear Me Out yet".
    func resolveContact(phone: String) async -> UserLookupResponse? {
        guard AppConfig.isBackendConfigured, auth.isAuthenticated else { return nil }
        do {
            return try await api.lookupUser(phone: SupabaseAuthManager.normalizePhone(phone))
        } catch {
            return nil
        }
    }

    func fetchHistoryEntries() async -> [CallHistoryEntry] {
        guard AppConfig.isBackendConfigured, auth.isAuthenticated else { return [] }
        do { return try await api.fetchHistory() }
        catch { print("history sync failed (best effort): \(error)"); return [] }
    }
}
