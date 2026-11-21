import SwiftUI

/// The incoming-call surface.
///
/// On a physical phone this is usually the system's own CallKit screen;
/// this is the in-app version, used on the simulator and as the fallback
/// when a call arrives over Realtime.
struct IncomingCallView: View {
    let callerName: String
    let answer: () -> Void
    let decline: () -> Void

    var body: some View {
        ZStack {
            Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.green)

                Text("Incoming call")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 20)

                Text(callerName)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.top, 6)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                HStack(spacing: 72) {
                    IncomingCallButton(
                        symbol: "phone.down.fill",
                        title: "Decline",
                        tint: Color(red: 1, green: 52 / 255, blue: 64 / 255),
                        action: decline
                    )

                    IncomingCallButton(
                        symbol: "phone.fill",
                        title: "Answer",
                        tint: .green,
                        action: answer
                    )
                }
                .padding(.bottom, 72)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// One of the two round buttons on the incoming-call screen.
private struct IncomingCallButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(tint, in: Circle())

                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
