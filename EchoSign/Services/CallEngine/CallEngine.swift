import Combine
import Foundation

/// What the user is calling. VoIP only for now — `.phoneNumber` is removed
/// on purpose rather than left as a dead/unsupported case; PSTN work is
/// shelved, not deleted (see project notes), and re-adding this case is
/// the right first step when that resumes, not something to leave half-wired
/// in the meantime.
enum CallTarget {
    case contact(id: String, displayName: String)
}

/// Events surfaced by a CallEngine for the view model to observe.
enum CallEngineEvent {
    case connecting
    case connected
    case remoteJoined
    case ended
    case failed(String)
}

/// Common surface `CallViewModel` drives, regardless of which engine is live.
/// The two engines share `AgoraService`/`CallKitManager`/`CaptionService`
/// underneath — this protocol only abstracts the pieces that genuinely
/// diverge: call setup (VoIP push+RTM join vs. backend-brokered PSTN bridge)
/// and where Type & Speak synthesis happens.
protocol CallEngine: AnyObject {
    var eventPublisher: AnyPublisher<CallEngineEvent, Never> { get }

    /// Both engines now synthesize sender-side — this is the shared
    /// controller driving highlighting and authoritative stop. The View
    /// binds to this directly rather than going through per-event plumbing.
    var typeAndSpeak: TypeAndSpeakController { get }

    func start(target: CallTarget) async throws
    func end()
    func toggleMute()
    func toggleSpeaker()

    /// Actual current mute state, read back from the engine's
    /// `MicDuckCoordinator` rather than tracked separately by the
    /// ViewModel — a second, independently-toggled bool there previously
    /// went stale relative to what `AgoraService` was actually doing.
    var isMuted: Bool { get }

    /// Synthesizes locally and injects into the outgoing track. Identical
    /// in both engines now — VoIP no longer sends this as text-only over
    /// RTM; RTM (where used) is a side-channel caption feed, not the
    /// primary transport for this call.
    func sendTypedText(_ text: String)

    /// The pause/stop button. Authoritative: nothing queued past this call
    /// reaches the far end.
    func stopSpeaking()
}
