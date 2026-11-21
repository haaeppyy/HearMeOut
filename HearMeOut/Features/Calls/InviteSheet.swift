import SwiftUI

/// The offer to invite someone who is not on HearMeOut yet.
///
/// Calling a number that is not registered would ring nothing, so the app
/// offers an invite instead.
struct InviteSheet: View {
    let displayName: String
    let phoneNumber: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text("Not on HearMeOut yet")
                .font(.system(size: 20, weight: .semibold))

            Text("\(displayName) hasn’t joined HearMeOut yet. Send them an invite so you can call them once they do.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ShareLink(item: inviteText) {
                Text("Share an invite")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.blue, in: Capsule())
            }
            .buttonStyle(.plain)

            Button("Close") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .presentationDetents([.medium])
    }

    private var inviteText: String {
        // The link is the one place the app points people at, so it is
        // worth getting right before this ships.
        "Join me on HearMeOut so we can call each other: https://hearmeout.app/invite"
    }
}
