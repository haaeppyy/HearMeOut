import SwiftUI

/// The call timer shown at the top of both call skins.
///
/// It reads the connection state rather than assuming the call connected:
/// a call that is still ringing says so, instead of quietly counting up
/// from the moment it was placed.
struct CallDurationLabel: View {
    let connectedAt: Date?
    var status: CallState = .connected

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(label(at: timeline.date))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private func label(at date: Date) -> String {
        switch status {
        case .connecting: return "Calling…"
        case .ringing: return "Ringing…"
        case .failed: return "Call failed"
        case .ended: return "Call ended"
        default: break
        }
        guard let connectedAt else { return "Calling…" }
        let seconds = max(0, Int(date.timeIntervalSince(connectedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
