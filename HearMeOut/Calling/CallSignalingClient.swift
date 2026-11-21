import Foundation

/// Result of creating a call. Simplified back to VoIP-only fields — the
/// PSTN-era `callType`/`provider`/`routeType` fields are gone along with
/// that code path; see project notes if that work resumes.
struct CallCreated {
    let callId: String
    let agoraChannel: String
    let rtcToken: String
    let rtmToken: String
    let uid: UInt
    /// Whether the callee's push notification actually went out — `false`
    /// doesn't mean the call failed, but the UI should probably show
    /// something more honest than an infinite ringing state if this comes
    /// back false (e.g. "they may not receive this call" rather than
    /// silently spinning forever).
    let pushDelivered: Bool
}

struct CallJoinInfo {
    let agoraChannel: String
    let rtcToken: String
    let rtmToken: String
    let uid: UInt
}

struct UserLookupResult {
    let id: String
    let displayName: String?
}

/// The user's own profile, as the server stores it.
struct ServerProfile {
    let id: String
    let displayName: String?
    let phone: String?
    let communicationProfile: String?
    let language: String?

    /// Whether the user has finished onboarding.
    ///
    /// The communication profile is the marker: it is only ever set once the
    /// user has told the app how they prefer to communicate, so a profile
    /// without one belongs to an account that has not been through
    /// onboarding yet.
    var hasCompletedOnboarding: Bool {
        communicationProfile?.isEmpty == false
    }
}

/// One call from the server's history.
///
/// This is the server's record of a call, including the ones that happened
/// while the app was closed.
struct ServerCallEntry {
    let callId: String
    let direction: CallDirection
    let otherPartyId: String?
    let otherPartyPhone: String?
    let otherPartyDisplayName: String?
    let status: CallOutcome
    let startedAt: Date?
    let connectedAt: Date?
    let endedAt: Date?
}

/// Client for the EchoSign signaling backend.
final class CallSignalingClient {

    private let baseURL: String
    private let session = URLSession.shared
    private let authTokenProvider: () async throws -> String

    init(baseURL: String, authTokenProvider: @escaping () async throws -> String) {
        self.baseURL = baseURL
        self.authTokenProvider = authTokenProvider
    }

    func createCall(target: CallTarget) async throws -> CallCreated {
        var request = URLRequest(url: URL(string: "\(baseURL)/calls")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")

        let calleeId: String
        switch target {
        case .contact(let id, _):
            calleeId = id
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["calleeId": calleeId])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callId = json["callId"] as? String,
              let agoraChannel = json["agoraChannel"] as? String,
              let rtcToken = json["rtcToken"] as? String,
              let rtmToken = json["rtmToken"] as? String,
              let uid = (json["uid"] as? NSNumber)?.uintValue else {
            throw SignalingError.malformedResponse
        }

        return CallCreated(
            callId: callId,
            agoraChannel: agoraChannel,
            rtcToken: rtcToken,
            rtmToken: rtmToken,
            uid: uid,
            pushDelivered: json["pushDelivered"] as? Bool ?? true
        )
    }

    /// Fetches a join token for a call someone else already created — used
    /// when answering an incoming call. `/calls` only issues a token for
    /// the caller's uid; the callee needs their own via this endpoint.
    func joinCall(callId: String) async throws -> CallJoinInfo {
        var request = URLRequest(url: URL(string: "\(baseURL)/call-join")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["callId": callId])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agoraChannel = json["agoraChannel"] as? String,
              let rtcToken = json["rtcToken"] as? String,
              let rtmToken = json["rtmToken"] as? String,
              let uid = (json["uid"] as? NSNumber)?.uintValue else {
            throw SignalingError.malformedResponse
        }

        return CallJoinInfo(agoraChannel: agoraChannel, rtcToken: rtcToken, rtmToken: rtmToken, uid: uid)
    }

    /// Ends a call.
    ///
    /// `outcome` says how the call ended, when the difference matters: a
    /// call the other party turned away is a decline, which is a different
    /// thing from a call that rang and was never picked up.
    func endCall(callId: String, outcome: CallOutcome? = nil) async throws {
        var request = try await authenticatedRequest(path: "call-end", method: "POST")
        var body: [String: String] = ["callId": callId]
        if outcome == .declined {
            body["outcome"] = CallOutcome.declined.rawValue
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    /// Fetches the server's record of this user's calls.
    ///
    /// This is what lets the app show calls that happened while it was
    /// closed — a call that was missed, or one that was answered on
    /// another device.
    func fetchCallHistory(limit: Int = 50) async throws -> [ServerCallEntry] {
        let request = try await authenticatedRequest(
            path: "call-history?limit=\(limit)",
            method: "GET"
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["calls"] as? [[String: Any]] else {
            throw SignalingError.malformedResponse
        }

        return entries.compactMap { entry in
            guard let callId = entry["callId"] as? String else { return nil }
            let direction: CallDirection = (entry["direction"] as? String) == "incoming"
                ? .incoming
                : .outgoing
            let otherParty = entry["otherParty"] as? [String: Any]
            return ServerCallEntry(
                callId: callId,
                direction: direction,
                otherPartyId: otherParty?["id"] as? String ?? entry["otherPartyId"] as? String,
                otherPartyPhone: otherParty?["phone"] as? String,
                otherPartyDisplayName: otherParty?["displayName"] as? String,
                status: CallOutcome(rawValue: entry["status"] as? String ?? "") ?? .failed,
                startedAt: Self.date(entry["startedAt"]),
                connectedAt: Self.date(entry["connectedAt"]),
                endedAt: Self.date(entry["endedAt"])
            )
        }
    }

    /// Parses a timestamp from the server.
    ///
    /// The server sends ISO-8601, sometimes with fractional seconds and
    /// sometimes without, so both have to be accepted — `ISO8601DateFormatter`
    /// with the default options rejects the fractional form outright.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Registers this device's APNs VoIP push token — call from
    /// `PushKitManager.pushRegistry(_:didUpdate:for:)`. Without this,
    /// incoming calls never ring on this device (see backend `push.ts`).
    func registerPushToken(_ token: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/push-token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pushToken": token])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    func savePhoneNumber(_ phone: String) async throws -> String {
        let saved = try await saveProfile(body: ["phone": phone])
        guard let phone = saved.phone else {
            throw SignalingError.malformedResponse
        }
        return phone
    }

    /// Writes the user's own profile.
    ///
    /// Only the fields present in `body` are sent, so a caller that wants to
    /// change one thing does not have to resend the rest.
    func saveProfile(body: [String: String]) async throws -> ServerProfile {
        var request = try await authenticatedRequest(path: "profile", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeProfile(data)
    }

    /// Reads the user's own profile, so a new device can be set up without
    /// asking them to type everything again.
    func fetchProfile() async throws -> ServerProfile {
        let request = try await authenticatedRequest(path: "profile", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeProfile(data)
    }

    private static func decodeProfile(_ data: Data) throws -> ServerProfile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SignalingError.malformedResponse
        }
        return ServerProfile(
            id: id,
            displayName: json["displayName"] as? String,
            phone: json["phone"] as? String,
            communicationProfile: json["communicationProfile"] as? String,
            language: json["language"] as? String
        )
    }

    func lookupUser(phone: String) async throws -> UserLookupResult {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encodedPhone = phone.addingPercentEncoding(withAllowedCharacters: allowed) ?? phone
        let request = try await authenticatedRequest(path: "users-lookup?phone=\(encodedPhone)", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SignalingError.malformedResponse
        }
        return UserLookupResult(id: id, displayName: json["displayName"] as? String)
    }

    private func authenticatedRequest(path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SignalingError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw SignalingError.serverError(status: http.statusCode, message: message)
        }
    }

    enum SignalingError: LocalizedError {
        case malformedResponse
        case serverError(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .malformedResponse: return "Signaling service returned an unexpected response"
            case .serverError(let status, let message): return message ?? "Signaling service error (\(status))"
            }
        }
    }

    // MARK: - Blocking

    /// Block a user so they cannot start outgoing or incoming calls.
    /// - Parameters:
    ///   - blockedId: The UUID of the user to block
    /// - Throws: If the user is already blocked, or the blocked user doesn't exist
    func blockUser(blockedId: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/block-user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["blockedId": blockedId])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    /// Unblock a user so they can start outgoing and incoming calls again.
    /// - Parameters:
    ///   - blockedId: The UUID of the user to unblock
    func unblockUser(blockedId: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/unblock-user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["blockedId": blockedId])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    /// Check if a user has been blocked by the current user.
    /// - Parameters:
    ///   - blockedId: The UUID of the user to check
    /// - Returns: true if the user is blocked, false otherwise
    func isBlocked(blockedId: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "\(baseURL)/users-lookup/\(blockedId)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["blocked"] as? Bool ?? false
    }
}
