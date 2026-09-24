import Combine
import Foundation

/// Test seam for CallCoordinator: the PushKit surface the coordinator
/// drives, without PKPushRegistry underneath.
///
/// PushKitManager already satisfies this — the extension below only adds the
/// Combine projection the coordinator subscribes to. Tests inject
/// FakePushKitManager, which lets a test synthesize an incoming push and
/// capture the completion the OS path depends on.
///
/// Stays on PushKitManager.IncomingPush (the parsed struct): parsing itself
/// is unit-tested separately via PushKitManager.parse, so the fakes and the
/// coordinator speak the same post-parse language as production.
protocol PushKitDriving: AnyObject {
    var voipToken: String? { get }
    /// Publisher form of the @Published voipToken the coordinator
    /// subscribes to (protocols can't witness a projected value directly).
    var voipTokenPublisher: AnyPublisher<String?, Never> { get }
    var onIncomingPush: ((PushKitManager.IncomingPush, @escaping () -> Void) -> Void)? { get set }
    func start()
}

extension PushKitManager: PushKitDriving {
    var voipTokenPublisher: AnyPublisher<String?, Never> {
        $voipToken.eraseToAnyPublisher()
    }
}
