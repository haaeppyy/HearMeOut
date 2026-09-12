import SwiftUI

/// Placeholder outgoing-call entry point — predates the real backend and
/// still describes a no-backend/temp-token flow in comments that's no
/// longer accurate. Left mostly as-is since real UI work is happening
/// separately, but the actual call-start wiring below was pointed at a
/// fully isolated `CallViewModel` that bypassed `AppCallCoordinator`
/// entirely — meaning it had its own `CallKitManager` instance, separate
/// from the one `PushKitManager` is registered against. That's fixed:
/// outgoing calls now go through the shared coordinator so CallKit state
/// stays consistent between outgoing and incoming calls.
struct DialerView: View {
    @EnvironmentObject private var callCoordinator: AppCallCoordinator
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

            TextField("Contact ID", text: $channelID)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .accessibilityLabel("Contact ID")
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

            Spacer()
            Spacer()
        }
        .padding()
        .navigationDestination(isPresented: $isPresentingCall) {
            if let callViewModel {
                CallView(viewModel: callViewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    EngineTestView()
                } label: {
                    Image(systemName: "waveform.badge.mic")
                }
                .accessibilityLabel("Engine test")
            }
        }
        .onChange(of: isPresentingCall) { _, presented in
            if !presented {
                callViewModel = nil
            }
        }
        // Picks up whichever CallViewModel AppCallCoordinator creates —
        // covers both outgoing calls started here and incoming calls
        // answered from the native CallKit UI while this screen happens
        // to be showing.
        .onReceive(callCoordinator.$activeCallViewModel) { viewModel in
            guard let viewModel else { return }
            callViewModel = viewModel
            isPresentingCall = true
        }
    }

    private func startCall() {
        let trimmed = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = callCoordinator.startOutgoingCall(target: .contact(id: trimmed, displayName: trimmed))
    }
}

#Preview {
    NavigationStack {
        DialerView()
            .environmentObject(AppCallCoordinator())
    }
}