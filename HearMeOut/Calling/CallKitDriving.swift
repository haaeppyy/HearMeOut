import Foundation

/// Test seam for CallCoordinator: the CallKit surface the coordinator
/// drives, without CXProvider/CXCallController underneath.
///
/// CallKitManager already satisfies this exactly (including the callback
/// properties) — the extension below is the whole conformance. Tests inject
/// FakeCallKitManager, which records requests instead of touching the
/// system phone UI.
///
/// Deliberately nonisolated: CallKitManager itself is a plain NSObject, and
/// the coordinator (which is @MainActor) can call nonisolated requirements
/// directly. The members the coordinator never touches (endAllCalls,
/// uuid(forCallId:)) are intentionally absent — protocol surface is the
/// coordinator's surface, not the manager's.
protocol CallKitDriving: AnyObject {
    var onAnswer: ((UUID) async -> Void)? { get set }
    var onEnd: ((UUID) async -> Void)? { get set }
    var onMuteChanged: ((UUID, Bool) -> Void)? { get set }
    var onStartCall: ((UUID) async -> Bool)? { get set }

    func requestOutgoing(contactName: String, uuid: UUID)
    func bind(callId: String, to uuid: UUID)
    func reportIncoming(callId: String, callerName: String, uuid: UUID, completion: @escaping (Error?) -> Void)
    func requestEnd(uuid: UUID)
    func forgetCall(uuid: UUID)
    func callId(forUUID uuid: UUID) -> String?
}

extension CallKitManager: CallKitDriving {}
