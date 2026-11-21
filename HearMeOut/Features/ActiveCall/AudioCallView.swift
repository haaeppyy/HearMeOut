import SwiftUI
import UIKit

/// The audio call skin.
///
/// Everything on this screen reads from the call's view model, so what is
/// on screen always matches what the call is actually doing. There is no
/// simulated connection here: the timer only starts once the call really
/// connects.
struct AudioCallView: View {
    @ObservedObject var viewModel: CallViewModel
    let contact: Contact?
    /// Offers to swap to the text skin.
    var showTextMode: (() -> Void)?
    /// Ends the call.
    let endCall: () -> Void

    @State private var isShowingContactCard = false

    var body: some View {
        ZStack {
            Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    CallDurationLabel(connectedAt: viewModel.connectedAt, status: viewModel.callState)

                    Text(viewModel.otherPartyDisplayName)
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
                        symbol: viewModel.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.wave.2",
                        title: "Audio"
                    ) {
                        viewModel.toggleSpeaker()
                    }
                    .position(x: sideButtonCenterX, y: topButtonCenterY + controlHeight / 2 - buttonSize / 2)

                    AudioCallControl(
                        symbol: viewModel.isMuted ? "mic.slash.fill" : "mic.slash",
                        title: "Mute"
                    ) {
                        viewModel.toggleMute()
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
                        endCall()
                    }
                        .position(x: proxy.size.width / 2, y: endButtonCenterY + controlHeight / 2 - buttonSize / 2)
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
                    Text(viewModel.otherPartyDisplayName)
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
}

/// One of the round controls on the audio call screen.
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

    /// Show the record button based on project decision.
    /// Currently hidden for v1 — real recording requires consent notice
    /// to the other party and is deferred to a future version.
    private var showRecordButton: Bool {
        false
    }

    // MARK: - VoiceOver Accessibility
    private var voiceOverLabels: some View {
        VStack {
            Label("Switch to audio", systemImage: "speaker.wave.3")
            Label("End call", systemImage: "phone.down")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Call controls: switch to audio mode, end call")
    }
