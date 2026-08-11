import AVFoundation
import SwiftUI

@main
struct EchoSignApp: App {

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DialerView()
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