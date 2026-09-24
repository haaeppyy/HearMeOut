import Foundation

/// Typed errors mapped 1:1 from the Edge Function contracts. The UI must
/// distinguish these — "no such user" and "rate limited" are different
/// screens, not a generic failure.
enum CallAPIError: Error, LocalizedError {
    case backendNotConfigured
    case unauthorized
    case calleeNotFound
    case cannotCallSelf
    case rateLimited
    case notYourCall
    case callGone
    case userNotFound
    case badRequest(String)
    case server(message: String, status: Int)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: return "Calling is not set up yet."
        case .unauthorized: return "You're signed out. Sign in and try again."
        case .calleeNotFound: return "This contact hasn't joined Hear Me Out yet."
        case .cannotCallSelf: return "You can't call yourself."
        case .rateLimited: return "Too many call attempts — try again shortly."
        case .notYourCall: return "This call isn't yours to join."
        case .callGone: return "This call is no longer active."
        case .userNotFound: return "No Hear Me Out account matches that number."
        case .badRequest(let m): return m
        case .server(let m, _): return m
        case .network(let e): return e.localizedDescription
        case .decoding: return "Couldn't understand the server response."
        }
    }
}

struct StartCallResponse: Decodable {
    let callId: String
    let agoraChannel: String
    let rtcToken: String
    let rtmToken: String
    let uid: Int
    let pushDelivered: Bool
}

struct JoinCallResponse: Decodable {
    let agoraChannel: String
    let rtcToken: String
    let rtmToken: String
    let uid: Int
}

struct EndCallResponse: Decodable {
    let ok: Bool
    let status: String
}

struct PushTokenResponse: Decodable {
    let ok: Bool
}

struct CallHistoryEntry: Decodable {
    let callId: String
    let direction: String
    let otherPartyId: String?
    let status: String
    let startedAt: Date?
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case callId, direction, otherPartyId, status, startedAt, endedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(String.self, forKey: .callId)
        direction = try c.decode(String.self, forKey: .direction)
        otherPartyId = try c.decodeIfPresent(String.self, forKey: .otherPartyId)
        status = try c.decode(String.self, forKey: .status)
        startedAt = Self.date(try c.decodeIfPresent(String.self, forKey: .startedAt))
        endedAt = Self.date(try c.decodeIfPresent(String.self, forKey: .endedAt))
    }

    /// Supabase timestamps carry fractional seconds
    /// (2026-09-23T12:00:00.123456+00:00), which JSONDecoder.iso8601 chokes
    /// on. Parse leniently: fractional first, plain second, nil never fatal.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        if let d = withFractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

struct CallHistoryResponse: Decodable {
    let calls: [CallHistoryEntry]
}

struct UserLookupResponse: Decodable {
    let id: String
    let displayName: String?
}

/// Thin REST client for the 5 active Edge Functions + users-lookup.
/// Raw URLSession (not supabase functions.invoke) so HTTP status codes stay
/// visible for the typed error mapping above.
struct CallAPIClient {
    var baseURL: URL
    var anonKey: String
    var tokenProvider: () async throws -> String
    /// Injectable for tests (mock URLProtocol). Production uses `.shared`.
    var session: URLSession = .shared

    init(tokenProvider: @escaping () async throws -> String) {
        self.baseURL = AppConfig.supabaseURL ?? URL(string: "https://localhost")!
        self.anonKey = AppConfig.supabaseAnonKey ?? ""
        self.tokenProvider = tokenProvider
    }

    // POST /functions/v1/calls { calleeId }
    func startCall(calleeId: String) async throws -> StartCallResponse {
        try await send(path: "/functions/v1/calls", method: "POST", body: ["calleeId": calleeId])
    }

    // POST /functions/v1/call-join { callId }
    // 403 "Not your call to join", 410 "This call is no longer active"
    func joinCall(callId: String) async throws -> JoinCallResponse {
        try await send(path: "/functions/v1/call-join", method: "POST", body: ["callId": callId])
    }

    // POST /functions/v1/call-end { callId } -> { ok, status }
    func endCall(callId: String) async throws -> EndCallResponse {
        try await send(path: "/functions/v1/call-end", method: "POST", body: ["callId": callId])
    }

    // GET /functions/v1/call-history?limit=&before=
    func fetchHistory(before: Date? = nil, limit: Int = 50) async throws -> [CallHistoryEntry] {
        var query = ["limit": "\(max(1, min(limit, 100)))"]
        if let before {
            query["before"] = ISO8601DateFormatter().string(from: before)
        }
        let response: CallHistoryResponse = try await send(path: "/functions/v1/call-history", method: "GET", body: nil, query: query)
        return response.calls
    }

    // POST /functions/v1/push-token { pushToken }
    func registerPushToken(_ token: String) async throws {
        let response: PushTokenResponse = try await send(path: "/functions/v1/push-token", method: "POST", body: ["pushToken": token])
        guard response.ok else { throw CallAPIError.server(message: "Failed to store push token", status: 200) }
    }

    // GET /functions/v1/users-lookup?phone=... -> { id, displayName } | 404
    func lookupUser(phone: String) async throws -> UserLookupResponse {
        return try await send(path: "/functions/v1/users-lookup", method: "GET", body: nil, query: ["phone": phone])
    }

    // MARK: - transport

    private func send<T: Decodable>(path: String, method: String, body: [String: String]?, query: [String: String]? = nil) async throws -> T {
        guard AppConfig.isBackendConfigured else { throw CallAPIError.backendNotConfigured }
        let token = try await tokenProvider()
        // Query items go through URLComponents: appendingPathComponent
        // percent-encodes "?" into the path (users-lookup%3Fphone=...),
        // which the gateway routes as a literal path → 404. This was a
        // real shipped bug — every GET-with-query from the app 404'd while
        // curl/contract tests (correct URLs) stayed green.
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if let query, !query.isEmpty {
            // Strict value encoding: URLComponents.queryItems leaves "+"
            // raw, and servers decode "+" as space (form encoding) — a
            // phone lookup for +1555... would search " 1555..." and 404.
            // Verified against the live function: %2B hits, raw + misses.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=")
            components?.percentEncodedQuery = query
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&")
        }
        guard let url = components?.url else { throw CallAPIError.badRequest("Couldn't build request URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CallAPIError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200...299:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw CallAPIError.decoding(error)
            }
        case 401:
            throw CallAPIError.unauthorized
        case 404:
            let message = Self.serverMessage(data)
            if path.contains("users-lookup") { throw CallAPIError.userNotFound }
            if message.lowercased().contains("callee") { throw CallAPIError.calleeNotFound }
            throw CallAPIError.server(message: message, status: 404)
        case 429:
            throw CallAPIError.rateLimited
        case 403:
            throw CallAPIError.notYourCall
        case 410:
            throw CallAPIError.callGone
        case 400:
            let message = Self.serverMessage(data)
            if message.lowercased().contains("yourself") { throw CallAPIError.cannotCallSelf }
            throw CallAPIError.badRequest(message)
        default:
            throw CallAPIError.server(message: Self.serverMessage(data), status: status)
        }
    }

    private static func serverMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        return "Something went wrong."
    }
}
