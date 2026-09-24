import SwiftUI
import UIKit

/// Audio call interface with a local recording timer for the Record control.
struct AudioCallView: View {
    let contactName: String
    var contact: Contact? = nil
    var callConnectedAt: Date? = nil
    var recordingEnabled = true
    var showTextMode: (() -> Void)?
    let endCall: (TimeInterval?) -> Void
    /// Backend wiring (Phase 5). When activeCall is set, mute/speaker/end
    /// and the connection clock are driven by Agora + ActiveCall instead of
    /// the simulated @State below. Nil = legacy local-only behavior.
    var activeCall: ActiveCall? = nil
    /// Observed (dummy by default so previews/legacy covers compile);
    /// backend behavior gates on `activeCall != nil`, never on this.
    @ObservedObject var agora = AgoraCallManager()
    var callKit: CallKitManager? = nil
    var onEndViaSystem: (() -> Void)? = nil
    /// Mic-duck coordinator (backend calls). Mute drives both the stream mute
    /// (CallKit-visible) and capture ducking (TTS interplay) — see
    /// CallCoordinator.setMuted for the unified path.
    var duck: MicDuckCoordinator? = nil
    @State private var isAudioActive = false
    @State private var isMuted = false
    @State private var isShowingContactCard = false
    @State private var isRecording = false
    @State private var recordingStartedAt: Date?
    @State private var recordedDuration: TimeInterval = 0
    @State private var localConnectedAt: Date?

    private var isBackendCall: Bool { activeCall != nil }
    private var showingMuted: Bool { isBackendCall ? agora.isMuted : isMuted }
    private var showingSpeakerOn: Bool { isBackendCall ? agora.speakerEnabled : isAudioActive }

    private var connectionStart: Date? {
        if isBackendCall { return activeCall?.connectedAt }
        return callConnectedAt ?? localConnectedAt
    }

    var body: some View {
        ZStack {
            Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    CallDurationLabel(connectedAt: connectionStart)

                    Text(contactName)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
                // The switch control ends 83 points from the top; keeping the
                // duration 32 points below it makes the call identity stable.
                .padding(.top, 115)
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)

            GeometryReader { proxy in
                // Measurements use the circular button bounds only. Labels are
                // positioned below their circles and do not change these gaps.
                let buttonSize: CGFloat = 64
                let labelHeight: CGFloat = 19
                let labelGap: CGFloat = 12
                let buttonBottomInset: CGFloat = 106
                let horizontalButtonGap: CGFloat = 54
                let verticalButtonGap: CGFloat = 48
                let endButtonCenterY = proxy.size.height - buttonBottomInset - buttonSize / 2
                let sideButtonCenterX = proxy.size.width / 2 - buttonSize - horizontalButtonGap
                let topButtonCenterY = endButtonCenterY - buttonSize - verticalButtonGap
                let controlHeight = buttonSize + labelGap + labelHeight

                ZStack {
                    AudioCallControl(
                        symbol: showingSpeakerOn ? "speaker.wave.2.fill" : "speaker.wave.2",
                        title: "Audio"
                    ) {
                        toggleSpeaker()
                    }
                    .position(x: sideButtonCenterX, y: topButtonCenterY + controlHeight / 2 - buttonSize / 2)

                    AudioCallControl(
                        symbol: showingMuted ? "mic.slash.fill" : "mic.slash",
                        title: "Mute"
                    ) {
                        toggleMute()
                    }
                    .position(x: proxy.size.width - sideButtonCenterX, y: topButtonCenterY + controlHeight / 2 - buttonSize / 2)

                    AudioCallControl(
                        symbol: isShowingContactCard ? "person.crop.circle.fill" : "person.crop.circle",
                        title: "Contact Card"
                    ) {
                        isShowingContactCard.toggle()
                    }
                    .position(x: sideButtonCenterX, y: endButtonCenterY + controlHeight / 2 - buttonSize / 2)

                    AudioCallControl(symbol: "phone.fill", title: "End", isEndButton: true) {
                        if let onEndViaSystem, isBackendCall {
                            onEndViaSystem()
                        } else {
                            endCall(finalRecordingDuration)
                        }
                    }
                        .position(x: proxy.size.width / 2, y: endButtonCenterY + controlHeight / 2 - buttonSize / 2)

                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        AudioCallControl(
                            symbol: isRecording ? "record.circle.fill" : "record.circle",
                            title: isRecording ? recordingTime(at: timeline.date) : "Record",
                            titleColor: isRecording ? .blue : .white.opacity(0.78),
                            isEnabled: recordingEnabled
                        ) {
                            toggleRecording()
                        }
                        .position(x: proxy.size.width - sideButtonCenterX, y: endButtonCenterY + controlHeight / 2 - buttonSize / 2)
                    }
                }
            }
            .ignoresSafeArea()

            if isShowingContactCard {
                contactCard
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
            }

            if let showTextMode {
                Button(action: showTextMode) {
                    HStack(spacing: 7) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 24, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 80, height: 48)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 35)
                .padding(.trailing, 20)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: isShowingContactCard)
        .onAppear {
            // Local-only mode fakes "connecting" with a timer. Backend calls
            // connect via ActiveCall.connectedAt instead — never fake it.
            guard !isBackendCall, callConnectedAt == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if localConnectedAt == nil { localConnectedAt = Date() }
            }
        }
    }

    /// Speaker toggle. Backend: one path drives both the in-app button and
    /// CallKit — route through AgoraCallManager either way.
    private func toggleSpeaker() {
        if isBackendCall {
            agora.setSpeakerphone(!agora.speakerEnabled)
        } else {
            isAudioActive.toggle()
        }
    }

    /// Mute toggle. Backend: update the stream mute AND capture ducking (a
    /// manually-muted user who then hears TTS must stay muted when it ends).
    /// (There is no CallKit mute-report API — mute is app-internal; the
    /// system mute button flows in via CXSetMutedCallAction instead.)
    private func toggleMute() {
        if isBackendCall {
            let newMuted = !agora.isMuted
            agora.setMuted(newMuted)
            duck?.setManuallyMuted(newMuted)
        } else {
            isMuted.toggle()
        }
    }

    private var contactCard: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { isShowingContactCard = false }

            VStack(spacing: 14) {
                if let data = contact?.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 82, height: 82)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 82, height: 82)
                }

                if let contact {
                    Text(contact.name)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(contact.phoneNumber)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                } else {
                    Text(contactName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Button("Done") { isShowingContactCard = false }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 290)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var finalRecordingDuration: TimeInterval? {
        guard isRecording || recordedDuration > 0 else { return nil }
        return recordedDuration + (recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func toggleRecording() {
        guard recordingEnabled else { return }
        if isRecording {
            if let recordingStartedAt {
                recordedDuration += Date().timeIntervalSince(recordingStartedAt)
            }
            self.recordingStartedAt = nil
            isRecording = false
        } else {
            recordingStartedAt = Date()
            isRecording = true
        }
    }

    private func recordingTime(at date: Date) -> String {
        let liveDuration = recordedDuration + (recordingStartedAt.map { date.timeIntervalSince($0) } ?? 0)
        let seconds = max(0, Int(liveDuration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

struct CallDurationLabel: View {
    let connectedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(label(at: timeline.date))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private func label(at date: Date) -> String {
        guard let connectedAt else { return "Calling mobile..." }
        let seconds = max(0, Int(date.timeIntervalSince(connectedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct AudioCallControl: View {
    let symbol: String
    let title: String
    var titleColor: Color = .white.opacity(0.78)
    var isEndButton = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: isEndButton ? 25 : 24, weight: .medium))
                    .foregroundStyle(isEndButton ? .white : .black)
                    .frame(width: 64, height: 64)
                    .background(isEndButton ? Color(red: 1, green: 52 / 255, blue: 64 / 255) : Color.white.opacity(0.68), in: Circle())

                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }
            .frame(width: 110, height: 95, alignment: .top)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}

#Preview("Calling") {
    AudioCallView(contactName: "Ridhhi", endCall: { _ in })
}

#Preview("Connected") {
    AudioCallView(contactName: "Ridhhi", callConnectedAt: Date().addingTimeInterval(-323), endCall: { _ in })
}
