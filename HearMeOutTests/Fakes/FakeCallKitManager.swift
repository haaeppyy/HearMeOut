import Foundation
import Testing

@testable import HearMeOut

/// Scriptable CallKitDriving test double: records every request instead of
/// touching CXCallController/CXProvider, and exposes the coordinator-wired
/// callbacks so tests drive the CXAction paths directly.
///
/// Mirrors CallKitManager's binding semantics: reportIncoming binds the
/// uuid→callId pair before completing (like the real manager binding
/// before reportNewIncomingCall's completion), and forgetCall drops it.
@MainActor
final class FakeCallKitManager: CallKitDriving {
    var onAnswer: ((UUID) async -> Void)?
    var onEnd: ((UUID) async -> Void)?
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onStartCall: ((UUID) async -> Bool)?

    private(set) var outgoingRequests: [(contactName: String, uuid: UUID)] = []
    private(set) var reportedIncoming: [(callId: String, callerName: String, uuid: UUID)] = []
    private(set) var endRequests: [UUID] = []
    private var bindings: [UUID: String] = [:]

    func requestOutgoing(contactName: String, uuid: UUID) {
        outgoingRequests.append((contactName, uuid))
    }

    func bind(callId: String, to uuid: UUID) {
        bindings[uuid] = callId
    }

    func reportIncoming(callId: String, callerName: String, uuid: UUID, completion: @escaping (Error?) -> Void) {
        reportedIncoming.append((callId, callerName, uuid))
        bindings[uuid] = callId
        completion(nil)
    }

    func requestEnd(uuid: UUID) {
        endRequests.append(uuid)
    }

    func forgetCall(uuid: UUID) {
        bindings[uuid] = nil
    }

    func callId(forUUID uuid: UUID) -> String? {
        bindings[uuid]
    }
}
