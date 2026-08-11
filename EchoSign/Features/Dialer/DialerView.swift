import SwiftUI

/// Outgoing-call entry point. The caller types the channel ID the callee agrees
/// to use and presses Call. No accounts, no backend — both phones just join the
/// same channel with the same ID (and the same temp token).
struct DialerView: View {
    @State private var channelID = Secrets.agoraChannelName
    @State private var callViewModel: CallViewModel?
    @State private var isPresentingCall = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("EchoSign")
                    .font(.largeTitle.bold())
                Text("App-to-app VoIP with live captions and Type & Speak.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("Channel ID", text: $channelID)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .disabled(true)
                .accessibilityLabel("Channel ID")
                .onSubmit { startCall() }

            Button(action: startCall) {
                Label("Call", systemImage: "phone.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 14)
                    .background(.green, in: Capsule())
            }
            .disabled(channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

            Text("The person you call must enter the same channel ID on their device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
        .padding()
        .navigationDestination(isPresented: $isPresentingCall) {
            if let callViewModel {
                CallView(viewModel: callViewModel)
            }
        }
        .onChange(of: isPresentingCall) { _, presented in
            if !presented {
                callViewModel = nil
            }
        }
    }

    private func startCall() {
        let trimmed = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let viewModel = CallViewModel(channelID: trimmed)
        callViewModel = viewModel
        isPresentingCall = true
        viewModel.startCall(channelID: trimmed)
    }
}

#Preview {
    NavigationStack {
        DialerView()
    }
}