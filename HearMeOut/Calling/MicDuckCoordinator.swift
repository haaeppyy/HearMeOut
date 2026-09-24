import Foundation

/// Single source of truth for microphone capture muting. `AgoraCallManager`
/// only exposes a setter (`setMicrophoneCaptureMuted`), no getter — and now
/// has two independent reasons to mute: the user's manual mute button, and
/// `AgoraPushSink` ducking the mic during Type & Speak playback. Without
/// coordination, whichever one fires `end()`/unmute last wins, silently
/// overriding the other — concretely: a user who manually mutes, then sends
/// a Type & Speak message, would get unmuted the moment that message
/// finishes, even though they never touched the mute button.
///
/// Actual mute state is the OR of both reasons; only when neither wants the
/// mic muted does it actually go live.
///
/// Ported from EchoSign's MicDuckCoordinator, repointed at AgoraCallManager.
final class MicDuckCoordinator {

    /// Protocol-typed (not concrete AgoraCallManager) so CallCoordinatorTests
    /// can drive the real coordinator logic against FakeAgoraCallManager.
    /// Only the nonisolated mute setter is touched — safe from any thread.
    private weak var agora: (any AgoraDriving)?
    private var manuallyMuted = false
    private var ttsDucking = false

    init(agora: any AgoraDriving) {
        self.agora = agora
    }

    /// Driven by the call screen's mute button.
    func setManuallyMuted(_ muted: Bool) {
        manuallyMuted = muted
        apply()
    }

    /// Driven by `AgoraPushSink.begin()`/`end()` around Type & Speak.
    func setTTSDucking(_ ducking: Bool) {
        ttsDucking = ducking
        apply()
    }

    var isManuallyMuted: Bool { manuallyMuted }

    private func apply() {
        agora?.setMicrophoneCaptureMuted(manuallyMuted || ttsDucking)
    }
}
