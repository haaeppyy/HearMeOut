import AVFoundation
import SwiftUI

@main
struct EchoSignApp: App {

    @StateObject private var callCoordinator = AppCallCoordinator()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DialerView()
                    .environmentObject(callCoordinator)
            }
            .onAppear {
                // Registers for VoIP pushes once, at app launch — not tied
                // to whether any particular call screen is on screen. This
                // has to happen here, not inside CallViewModel, or an
                // incoming call while the user is anywhere else in the app
                // would never be caught at all.
                callCoordinator.start()
            }
        }
    }

    /// Configure the audio session before any call starts so Agora and the
    /// speech services inherit the voice-call route. Agora may re-apply its
    /// own session settings on join; this guarantees a sensible baseline.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        } catch {
            assertionFailure("Failed to configure the audio session: \(error)")
        }
    }
}