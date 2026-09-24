import Foundation
import Testing

@testable import HearMeOut

/// URLProtocol stub: scripted (status, JSON) per test, no network.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, json) = try MockURLProtocol.handler?(request) ?? (500, [:])
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

/// HTTP status → CallAPIError matrix, one case per backend contract.
///
/// Serialized: tests share one static URLProtocol handler, so parallel
/// execution would cross-wire scripted responses between cases.
@Suite("CallAPIClient error mapping", .serialized)
struct CallAPIClientTests {

    private func client(replying status: Int, json: [String: Any] = [:]) -> CallAPIClient {
        MockURLProtocol.handler = { _ in (status, json) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var client = CallAPIClient(tokenProvider: { "test-jwt" })
        client.baseURL = URL(string: "https://test.invalid")!
        client.anonKey = "test-anon"
        client.session = URLSession(configuration: config)
        return client
    }

    private func assertThrows<T>(
        _ expression: @escaping () async throws -> T,
        matches: (CallAPIError) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await expression()
            Issue.record("expected throw", sourceLocation: sourceLocation)
        } catch let error as CallAPIError {
            #expect(matches(error), "got: \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("wrong error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("401 → unauthorized")
    func unauthorized() async {
        let client = client(replying: 401, json: ["error": "Unauthorized"])
        await assertThrows({ try await client.fetchHistory() }) {
            if case .unauthorized = $0 { return true }
            return false
        }
    }

    @Test("calls 404 mentioning callee → calleeNotFound")
    func calleeNotFound() async {
        let client = client(replying: 404, json: ["error": "Callee not found"])
        await assertThrows({ try await client.startCall(calleeId: "nope") }) {
            if case .calleeNotFound = $0 { return true }
            return false
        }
    }

    @Test("lookup 404 → userNotFound (not calleeNotFound)")
    func lookupNotFound() async {
        let client = client(replying: 404, json: ["error": "User not found"])
        await assertThrows({ try await client.lookupUser(phone: "+1000") }) {
            if case .userNotFound = $0 { return true }
            return false
        }
    }

    @Test("429 → rateLimited")
    func rateLimited() async {
        let client = client(replying: 429, json: ["error": "Too many call attempts — try again shortly"])
        await assertThrows({ try await client.startCall(calleeId: "x") }) {
            if case .rateLimited = $0 { return true }
            return false
        }
    }

    @Test("join 403 → notYourCall, 410 → callGone")
    func joinGuards() async {
        await assertThrows({ try await client(replying: 403, json: ["error": "Not your call to join"]).joinCall(callId: "c") }) {
            if case .notYourCall = $0 { return true }
            return false
        }
        await assertThrows({ try await client(replying: 410, json: ["error": "This call is no longer active"]).joinCall(callId: "c") }) {
            if case .callGone = $0 { return true }
            return false
        }
    }

    @Test("400 mentioning yourself → cannotCallSelf")
    func selfCall() async {
        let client = client(replying: 400, json: ["error": "Cannot call yourself"])
        await assertThrows({ try await client.startCall(calleeId: "me") }) {
            if case .cannotCallSelf = $0 { return true }
            return false
        }
    }

    @Test("happy-path payloads decode")
    func happyPaths() async throws {
        let start = client(replying: 200, json: [
            "callId": "id-1", "agoraChannel": "ch", "rtcToken": "rtc",
            "rtmToken": "rtm", "uid": 7, "pushDelivered": false,
        ])
        let started = try await start.startCall(calleeId: "them")
        #expect(started.callId == "id-1")
        #expect(started.uid == 7)
        #expect(started.pushDelivered == false)

        let end = client(replying: 200, json: ["ok": true, "status": "ended"])
        let ended = try await end.endCall(callId: "id-1")
        #expect(ended.status == "ended")

        let lookup = client(replying: 200, json: ["id": "u-9", "displayName": "Priya"])
        let hit = try await lookup.lookupUser(phone: "+1555")
        #expect(hit.id == "u-9")
        #expect(hit.displayName == "Priya")
    }

    // MARK: - transport paths (same serialized suite: shared static handler)

    private func client(
        handler: ((URLRequest) throws -> (Int, [String: Any]))?,
        tokenProvider: @escaping () async throws -> String = { "test-jwt" }
    ) -> CallAPIClient {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var client = CallAPIClient(tokenProvider: tokenProvider)
        client.baseURL = URL(string: "https://test.invalid")!
        client.anonKey = "test-anon"
        client.session = URLSession(configuration: config)
        return client
    }

    /// Lock-guarded request capture: the protocol stub runs on the session's
    /// queue, not the test's thread.
    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
        }
        var last: URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return requests.last
        }
    }

    @Test("throwing token provider propagates raw (not wrapped in .network)")
    func tokenProviderPassthrough() async {
        struct Boom: Error {}
        let client = client(handler: nil, tokenProvider: { throw Boom() })
        do {
            _ = try await client.fetchHistory()
            Issue.record("expected throw")
        } catch is Boom {
            // send() awaits the provider outside its do/catch — the raw
            // error (e.g. unauthorized from a dead session) reaches callers.
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("throwing session becomes .network")
    func sessionThrowIsNetwork() async {
        struct Offline: Error {}
        let client = client(handler: { _ in throw Offline() })
        await assertThrows({ try await client.startCall(calleeId: "x") }) {
            if case .network = $0 { return true }
            return false
        }
    }

    @Test("200 with undecodable body becomes .decoding")
    func badBodyIsDecoding() async {
        let client = client(handler: { _ in (200, ["wrong": "shape"]) })
        await assertThrows({ try await client.startCall(calleeId: "x") }) {
            if case .decoding = $0 { return true }
            return false
        }
    }

    @Test("fetchHistory clamps limit and encodes before")
    func historyQuery() async throws {
        let box = CaptureBox()
        let client = client(handler: { request in
            box.append(request)
            return (200, ["calls": []])
        })

        _ = try await client.fetchHistory()
        #expect(box.last?.url?.path.hasSuffix("/call-history") == true)
        #expect(box.last?.url?.query?.contains("limit=50") == true)

        _ = try await client.fetchHistory(limit: 500)
        #expect(box.last?.url?.query?.contains("limit=100") == true)

        _ = try await client.fetchHistory(limit: 0)
        #expect(box.last?.url?.query?.contains("limit=1") == true)

        _ = try await client.fetchHistory(before: Date(timeIntervalSince1970: 1_700_000_000))
        let url = box.last?.url
        #expect(url?.query?.contains("limit=50") == true)
        #expect(url?.query?.contains("before=") == true)
        // Regression: the query must be a real query, not percent-encoded
        // into the path (appendingPathComponent turned "?" into %3F, so
        // every GET-with-query 404'd while curl stayed green).
        #expect(url?.absoluteString.contains("%3F") == false)
    }

    @Test("lookupUser puts the phone in a real query, plus-sign encoded")
    func lookupQuery() async throws {
        let box = CaptureBox()
        let client = client(handler: { request in
            box.append(request)
            return (200, ["id": "u-9"])
        })
        _ = try await client.lookupUser(phone: "+15551234567")
        let url = box.last?.url
        #expect(url?.path.hasSuffix("/users-lookup") == true)
        #expect(url?.query?.contains("phone=") == true)
        // "+" must survive as %2B — urlQueryAllowed hand-encoding dropped it.
        #expect(url?.absoluteString.contains("%3F") == false)
        #expect(url?.absoluteString.contains("+1555") == false)
    }

    @Test("push-token ok:false throws .server, ok:true succeeds silently")
    func pushTokenBranches() async throws {
        let failing = client(handler: { _ in (200, ["ok": false]) })
        await assertThrows({ try await failing.registerPushToken("tok") }) {
            if case .server(let message, let status) = $0 {
                return status == 200 && message == "Failed to store push token"
            }
            return false
        }

        let passing = client(handler: { _ in (200, ["ok": true]) })
        try await passing.registerPushToken("tok")
    }
}
