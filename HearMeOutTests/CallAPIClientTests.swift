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
}
