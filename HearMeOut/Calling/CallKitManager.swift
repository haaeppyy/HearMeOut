import CallKit
import Foundation

/// Owns CXProvider + CXCallController. The app never builds a custom
/// incoming-call screen — CallKit's native UI is the incoming UI.
///
/// Async contract: delegate callbacks (answer/end/mute/start) forward to the
/// coordinator's async handlers and fulfill the CXAction only after the work
/// completes, so the system UI never lies about the call state.
final class CallKitManager: NSObject, ObservableObject {
    var onAnswer: ((UUID) async -> Void)?
    var onEnd: ((UUID) async -> Void)?
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onStartCall: ((UUID) async -> Bool)?

    /// callUUID -> server callId for every call CallKit knows about.
    private var callIdsByUUID: [UUID: String] = [:]
    private var uuidsByCallId: [String: UUID] = [:]

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Nonisolated so the app graph can be built in HearMeOutApp.init.
    nonisolated     override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        // NSSet<NSNumber *> in ObjC, Set<CXHandle.HandleType> in Swift.
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - outgoing

    /// Request the system start an outgoing call. The server callId isn't
    /// known until startCall returns inside performOutgoing, so bind it
    /// afterwards via bind(callId:to:). The actual API work happens in
    /// provider(_:perform: CXStartCallAction) — fulfill there, once the
    /// channel join succeeds, not before.
    func requestOutgoing(contactName: String, uuid: UUID) {
        let handle = CXHandle(type: .generic, value: contactName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.contactIdentifier = contactName
        callController.request(CXTransaction(action: action)) { error in
            if let error { print("CXStartCallAction failed: \(error)") }
        }
    }

    /// Associate a server callId with a CallKit UUID once startCall returns.
    func bind(callId: String, to uuid: UUID) {
        callIdsByUUID[uuid] = callId
        uuidsByCallId[callId] = uuid
    }

    // MARK: - incoming

    /// Must be called synchronously from the PushKit callback path.
    func reportIncoming(callId: String, callerName: String, uuid: UUID, completion: @escaping (Error?) -> Void = { _ in }) {
        callIdsByUUID[uuid] = callId
        uuidsByCallId[callId] = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }

    // MARK: - in-call controls

    func requestEnd(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error { print("CXEndCallAction failed: \(error)") }
        }
    }

    func endAllCalls() {
        for uuid in callIdsByUUID.keys {
            requestEnd(uuid: uuid)
        }
    }

    func forgetCall(uuid: UUID) {
        if let callId = callIdsByUUID.removeValue(forKey: uuid) {
            uuidsByCallId.removeValue(forKey: callId)
        }
    }

    func uuid(forCallId callId: String) -> UUID? {
        uuidsByCallId[callId]
    }

    func callId(forUUID uuid: UUID) -> String? {
        callIdsByUUID[uuid]
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        callIdsByUUID.removeAll()
        uuidsByCallId.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            await onAnswer?(action.callUUID)
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            await onEnd?(action.callUUID)
            forgetCall(uuid: action.callUUID)
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMuteChanged?(action.callUUID, action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            let ok = await onStartCall?(action.callUUID) ?? false
            if ok {
                action.fulfill()
            } else {
                action.fail()
                forgetCall(uuid: action.callUUID)
            }
        }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        print("CallKit action timed out: \(action)")
    }
}
