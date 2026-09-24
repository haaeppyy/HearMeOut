import Foundation
import Testing

@testable import HearMeOut

/// CallCoordinator orchestration against fakes + scripted HTTP — no
/// CallKit/PushKit/Agora frameworks, no network, no device.
///
/// The private workers (performOutgoing/handleIncomingPush/answerCall) are
/// reached through the same public seams the system uses: startOutgoing →
/// the fake's recorded onStartCall, activate() → the fake's recorded
/// onIncomingPush/onAnswer, finishAudioCall/finishTextCall → finalize.
///
/// Serialized within the suite (own static stub handler), and mutates the
/// defaultCallingInterface default — restored per test.
@Suite("CallCoordinator orchestration", .serialized)
@MainActor
struct CallCoordinatorTests {

    private struct Graph {
        let coordinator: CallCoordinator
        let auth: SupabaseAuthManager
        let callKit: FakeCallKitManager
        let pushKit: FakePushKitManager
        let agora: FakeAgoraCallManager
        let active: ActiveCall
    }

    private func requestCount(containing fragment: String) -> Int {
        CoordinatorURLProtocol.recorded.filter {
            $0.url?.absoluteString.contains(fragment) == true
        }.count
    }

/// Dedicated URLProtocol stub for this suite. MockURLProtocol (in
/// CallAPIClientTests) is shared with that suite, and Swift Testing runs
/// suites in parallel — reusing one static handler across both suites
/// cross-wires scripted responses. This stub has its own static handler
/// plus lock-guarded request capture, so the two suites stay independent.
final class CoordinatorURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static func reset(handler: ((URLRequest) throws -> (Int, [String: Any]))?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }

    static var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, json) = try Self.handler?(request) ?? (500, [:])
            Self.lock.lock()
            Self.requests.append(request)
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: json)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

    private func makeGraph(
        handler: ((URLRequest) throws -> (Int, [String: Any]))? = nil
    ) -> Graph {
        CoordinatorURLProtocol.reset(handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoordinatorURLProtocol.self]
        var api = CallAPIClient(tokenProvider: { "test-jwt" })
        api.baseURL = URL(string: "https://test.invalid")!
        api.anonKey = "test-anon"
        api.session = URLSession(configuration: config)
        let auth = SupabaseAuthManager()
        auth.setAuthenticatedForTests(true)
        let active = ActiveCall()
        let callKit = FakeCallKitManager()
        let pushKit = FakePushKitManager()
        let agora = FakeAgoraCallManager()
        let coordinator = CallCoordinator(
            auth: auth, active: active,
            callKit: callKit, pushKit: pushKit, agora: agora, api: api
        )
        return Graph(
            coordinator: coordinator, auth: auth,
            callKit: callKit, pushKit: pushKit,
            agora: agora, active: active
        )
    }

    /// activate() wires the fakes' callbacks (the only way to reach the
    /// private push/answer paths). It also runs auth.restore(), which clears
    /// the test flag — no persisted session exists in unit tests — so the
    /// flag is re-applied after, mirroring a signed-in launch.
    private func activated(_ graph: Graph) -> Graph {
        graph.coordinator.activate()
        graph.auth.setAuthenticatedForTests(true)
        #expect(graph.pushKit.startCount == 1)
        return graph
    }

    private func linkedContact(name: String = "Priya") -> Contact {
        Contact(name: name, phoneNumber: "+1555", isFavorite: false, remoteUserID: "remote-9")
    }

    private func unlinkedContact(name: String = "Amar") -> Contact {
        Contact(name: name, phoneNumber: "+1666", isFavorite: false, remoteUserID: nil)
    }

    private func startCallJSON(pushDelivered: Bool = true) -> [String: Any] {
        ["callId": "c-1", "agoraChannel": "ch-1", "rtcToken": "rtc",
         "rtmToken": "rtm", "uid": 7, "pushDelivered": pushDelivered]
    }

    private func joinCallJSON() -> [String: Any] {
        ["agoraChannel": "ch-1", "rtcToken": "rtc", "rtmToken": "rtm", "uid": 7]
    }

    /// Fire-and-forget Task hops (startOutgoing's lookup, the push path,
    /// finalize) need a polling join — a single yield doesn't guarantee
    /// the hop ran.
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @autoclosure () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for condition", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    // MARK: - outgoing guard chain

    @Test("startOutgoing while live sets the busy alert and skips CallKit")
    func busyStartOutgoing() {
        let graph = makeGraph()
        graph.active.configureOutgoing(contactName: "Priya", contact: linkedContact())
        graph.coordinator.startOutgoing(to: linkedContact(), mode: "Text Mode")
        #expect(graph.coordinator.alertMessage == "You're already on a call.")
        #expect(graph.callKit.outgoingRequests.isEmpty)
    }

    @Test("unlinked contact, lookup 404 → not-joined alert, state reset, no CallKit")
    func lookupMissResets() async {
        let graph = makeGraph(handler: { _ in (404, ["error": "User not found"]) })
        graph.coordinator.startOutgoing(to: unlinkedContact(), mode: "Text Mode")
        await waitUntil(graph.coordinator.alertMessage != nil)
        #expect(graph.coordinator.alertMessage?.contains("hasn't joined Hear Me Out yet") == true)
        #expect(graph.active.isLive == false)
        #expect(graph.callKit.outgoingRequests.isEmpty)
    }

    @Test("unlinked contact, lookup hit → linkedContact published, CallKit proceeds")
    func lookupHitLinks() async {
        let graph = makeGraph(handler: { _ in (200, ["id": "remote-9", "displayName": "Priya"]) })
        let contact = unlinkedContact()
        graph.coordinator.startOutgoing(to: contact, mode: "Text Mode")
        await waitUntil(graph.callKit.outgoingRequests.count == 1)
        #expect(graph.coordinator.linkedContact?.localID == contact.id)
        #expect(graph.coordinator.linkedContact?.remoteID == "remote-9")
        #expect(graph.callKit.outgoingRequests.first?.uuid == graph.active.callUUID)
    }

    @Test("already-linked contact dials with no lookup call")
    func linkedSkipsLookup() async {
        let graph = makeGraph(handler: { _ in (200, ["id": "remote-9"]) })
        graph.coordinator.startOutgoing(to: linkedContact(), mode: "Text Mode")
        await waitUntil(graph.callKit.outgoingRequests.count == 1)
        #expect(requestCount(containing: "users-lookup") == 0)
    }

    // MARK: - performOutgoing via the recorded onStartCall

    @Test("onStartCall success binds, activates, presents, and warns (not blocks) on pushDelivered:false")
    func performOutgoingWarnsNotBlocks() async {
        // onStartCall is wired by activate() (like the CXStartCallAction
        // path) — startOutgoing alone only queues the pending context.
        let graph = activated(makeGraph(handler: { _ in (200, startCallJSON(pushDelivered: false)) }))
        graph.coordinator.startOutgoing(to: linkedContact(), mode: "Text Mode")
        await waitUntil(graph.callKit.outgoingRequests.count == 1)
        let uuid = graph.active.callUUID
        let ok = await graph.callKit.onStartCall?(uuid) ?? false
        #expect(ok == true)
        #expect(graph.callKit.callId(forUUID: uuid) == "c-1")
        #expect(graph.active.phase == .active)
        #expect(graph.coordinator.textRequest != nil)
        #expect(graph.coordinator.audioRequest == nil)
        // Warn-not-block: the call proceeds AND the user is told it may not ring.
        #expect(graph.coordinator.alertMessage?.contains("may not ring") == true)
    }

    @Test("onStartCall API failure returns false, alerts, binds nothing")
    func performOutgoingFailure() async {
        let graph = activated(makeGraph(handler: { _ in (429, ["error": "Too many"]) }))
        graph.coordinator.startOutgoing(to: linkedContact(), mode: "Audio Mode")
        await waitUntil(graph.callKit.outgoingRequests.count == 1)
        let uuid = graph.active.callUUID
        let ok = await graph.callKit.onStartCall?(uuid) ?? true
        #expect(ok == false)
        #expect(graph.coordinator.alertMessage?.contains("Too many") == true)
        #expect(graph.callKit.callId(forUUID: uuid) == nil)
        #expect(graph.coordinator.audioRequest == nil)
    }

    // MARK: - incoming push via the recorded onIncomingPush

    @Test("push while live busy-declines via endCall, never reports, still completes")
    func busyIncomingDeclines() async {
        let graph = activated(makeGraph(handler: { _ in (200, ["ok": true, "status": "missed"]) }))
        graph.active.configureOutgoing(contactName: "Priya", contact: linkedContact())
        var completed = false
        graph.pushKit.simulateIncomingPush(FakePushKitManager.push()) { completed = true }
        await waitUntil(completed)
        // Busy: the caller gets `missed` via endCall — never a second ringing line.
        await waitUntil(requestCount(containing: "call-end") == 1)
        #expect(graph.callKit.reportedIncoming.isEmpty)
        #expect(completed == true)
    }

    @Test("push while idle configures incoming and reports exactly once")
    func idleIncomingReports() async {
        let graph = activated(makeGraph())
        var completed = false
        let push = FakePushKitManager.push(callId: "call-7", channel: "ch-7", callerName: "Amar")
        graph.pushKit.simulateIncomingPush(push) { completed = true }
        await waitUntil(completed)
        #expect(graph.active.callId == "call-7")
        #expect(graph.active.channel == "ch-7")
        #expect(graph.active.phase == .ringing(pushDelivered: true))
        #expect(graph.callKit.reportedIncoming.count == 1)
        #expect(graph.callKit.reportedIncoming.first?.callId == "call-7")
        #expect(graph.callKit.reportedIncoming.first?.callerName == "Amar")
        #expect(graph.callKit.reportedIncoming.first?.uuid == graph.active.callUUID)
    }

    // MARK: - answerCall via the recorded onAnswer

    @Test("answer success joins media with the response and presents per default interface")
    func answerSuccess() async {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "defaultCallingInterface")
        defaults.set("Audio Mode", forKey: "defaultCallingInterface")
        defer {
            if let saved { defaults.set(saved, forKey: "defaultCallingInterface") }
            else { defaults.removeObject(forKey: "defaultCallingInterface") }
        }

        let graph = activated(makeGraph(handler: { _ in (200, joinCallJSON()) }))
        var completed = false
        graph.pushKit.simulateIncomingPush(FakePushKitManager.push()) { completed = true }
        await waitUntil(completed)
        await graph.callKit.onAnswer?(graph.active.callUUID)

        #expect(graph.agora.joinedAudio.count == 1)
        #expect(graph.agora.joinedAudio.first?.channel == "ch-1")
        #expect(graph.agora.joinedAudio.first?.token == "rtc")
        #expect(graph.agora.joinedAudio.first?.uid == 7)
        #expect(graph.agora.joinedMessaging.count == 1)
        #expect(graph.agora.joinedMessaging.first?.token == "rtm")
        #expect(graph.active.phase == .active)
        #expect(graph.coordinator.audioRequest != nil)
        #expect(graph.coordinator.textRequest == nil)
    }

    @Test("answer API failure fails the call, alerts, and forgets the binding")
    func answerFailure() async {
        let graph = activated(makeGraph(handler: { _ in (403, ["error": "Not your call"]) }))
        var completed = false
        graph.pushKit.simulateIncomingPush(FakePushKitManager.push()) { completed = true }
        await waitUntil(completed)
        let uuid = graph.active.callUUID
        await graph.callKit.onAnswer?(uuid)
        #expect(graph.active.phase == .ended(status: "failed"))
        #expect(graph.coordinator.alertMessage?.contains("isn't yours") == true)
        // A missed forget-call leaks a stale UUID binding for the app run.
        #expect(graph.callKit.callId(forUUID: uuid) == nil)
    }

    // MARK: - ending

    @Test("double finish finalizes exactly once")
    func finalizeOnce() async {
        let graph = activated(makeGraph(handler: { _ in (200, ["ok": true, "status": "ended"]) }))
        var completed = false
        graph.pushKit.simulateIncomingPush(FakePushKitManager.push()) { completed = true }
        await waitUntil(completed)
        graph.coordinator.finishAudioCall(recordingDuration: nil)
        graph.coordinator.finishAudioCall(recordingDuration: nil)
        await waitUntil(requestCount(containing: "call-end") == 1)
        // finalize's tail (leaveAll → active.end → finishedCall) needs
        // several hops after the request is recorded — join on the end
        // state itself, not on a fixed number of yields.
        await waitUntil(graph.coordinator.finishedCall != nil)
        #expect(requestCount(containing: "call-end") == 1)
        #expect(graph.active.phase == .ended(status: "ended"))
        #expect(graph.coordinator.finishedCall != nil)
    }

    // MARK: - speech plane entry

    @Test("speakAndSend with no channel throws backendNotConfigured without touching Agora")
    func speakWithoutChannel() async {
        let graph = makeGraph()
        do {
            try await graph.coordinator.speakAndSend("hello")
            Issue.record("expected throw")
        } catch let error as CallAPIError {
            if case .backendNotConfigured = error {
            } else {
                Issue.record("expected .backendNotConfigured, got: \(error)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(graph.agora.sentMessages.isEmpty)
    }
}
