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
        if !Secrets.hasRealBackend {
            let channel = "test-\(UUID().uuidString.prefix(8))"
            let uid = UInt.random(in: 1...999999)
            return CallCreated(
                callId: "local-\(UUID().uuidString.prefix(8))",
                agoraChannel: channel,
                rtcToken: Secrets.agoraTempToken,
                rtmToken: Secrets.agoraTempToken,
                uid: uid,
                pushDelivered: false
            )
        }

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
        if !Secrets.hasRealBackend {
            let uid = UInt.random(in: 1...999999)
            return CallJoinInfo(
                agoraChannel: Secrets.agoraChannelName,
                rtcToken: Secrets.agoraTempToken,
                rtmToken: Secrets.agoraTempToken,
                uid: uid
            )
        }

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

    func endCall(callId: String) async throws {
        guard Secrets.hasRealBackend else { return }

        var request = URLRequest(url: URL(string: "\(baseURL)/call-end")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["callId": callId])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    /// Registers this device's APNs VoIP push token — call from
    /// `PushKitManager.pushRegistry(_:didUpdate:for:)`. Without this,
    /// incoming calls never ring on this device (see backend `push.ts`).
    func registerPushToken(_ token: String) async throws {
        guard Secrets.hasRealBackend else { return }

        var request = URLRequest(url: URL(string: "\(baseURL)/push-token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pushToken": token])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
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
}
