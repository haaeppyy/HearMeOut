import SwiftUI

/// The text call skin.
///
/// What the other person says arrives either as live captions from the
/// speech recogniser, or — when they are on HearMeOut too — as the exact
/// text they typed, over the data stream. What this user types is spoken
/// to them and also sent as exact text.
///
/// The composer stays disabled until the call really connects, and the
/// "save the conversation?" prompt is asked before the call is ended, so
/// the transcript is only kept when the user wants it.
struct TextCallView: View {
    @ObservedObject var viewModel: CallViewModel
    let contact: Contact?
    /// Offers to swap to the audio skin.
    var showAudioMode: (() -> Void)?
    /// Ends the call.
    let endCall: () -> Void

    @State private var reply = ""
    @State private var showsSavePrompt = false
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        ZStack {
            Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if conversation.isEmpty && liveCaption == nil {
                            Text("What the other person says will appear here as captions.")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 40)
                                .padding(.horizontal, 36)
                        }

                        ForEach(conversation) { segment in
                            CallBubble(text: segment.text, isLocal: segment.speaker == .me)
                        }

                        if let liveCaption {
                            liveCaptionView(liveCaption)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 22)
                    .padding(.horizontal, 36)
                }
                .frame(maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)

                if viewModel.isSpeaking {
                    speakingStrip
                        .padding(.horizontal, 26)
                        .padding(.bottom, 10)
                }

                composer.padding(.bottom, 28)
            }
            .blur(radius: showsSavePrompt ? 5 : 0)

            if showsSavePrompt { savePrompt }
        }
        .preferredColorScheme(.dark)
        .alert("HearMeOut", isPresented: errorBinding) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                CallDurationLabel(connectedAt: viewModel.connectedAt, status: viewModel.callState)
                Text(viewModel.otherPartyDisplayName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }

            HStack {
                if let showAudioMode {
                    Button { showAudioMode() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                            Image(systemName: "speaker.wave.2").font(.system(size: 24, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(width: 78, height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch to audio")
                }
                Spacer()
                VStack(spacing: 12) {
                    Button { showsSavePrompt = true } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(Color(red: 1, green: 52 / 255, blue: 64 / 255), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End call")
                    Text("End").font(.system(size: 16)).foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 26)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $reply,
                prompt: Text(canSend ? "enter ur reply here" : "waiting for the call to connect")
                    .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
            )
                .font(.system(size: 15))
                .foregroundStyle(.black)
                .focused($isReplyFocused)
                .submitLabel(.send)
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 43, height: 43)
                    .background(Color.black.opacity(0.76), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel("Send typed message")
        }
        .padding(.leading, 20)
        .padding(.trailing, 7)
        .frame(width: 346, height: 57)
        .background(Color(red: 220 / 255, green: 220 / 255, blue: 225 / 255), in: Capsule())
    }

    private var canSend: Bool {
        viewModel.callState == .connected
            && !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - What is being said

    /// The settled conversation so far, in the order it happened.
    private var conversation: [TranscriptSegment] {
        viewModel.transcriptSegments
    }

    /// The line currently being transcribed, if there is one.
    private var liveCaption: CaptionService.CaptionLine? {
        viewModel.captionLog.last(where: { !$0.isFinal })
    }

    private func liveCaptionView(_ line: CaptionService.CaptionLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LIVE CAPTIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(line.text.isEmpty ? "…" : line.text)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.text.isEmpty ? "Transcribing" : "Transcribing: \(line.text)")
    }

    /// The strip that shows what this user is currently having spoken, with
    /// the word being spoken picked out, and a button to stop it.
    private var speakingStrip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NOW SPEAKING")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                spokenText
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { viewModel.stopSpeaking() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop speaking")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The text being spoken, with the word being spoken right now picked
    /// out.
    private var spokenText: Text {
        let text = viewModel.spokenText
        if let range = viewModel.highlightedRange,
           let swiftRange = Range(range, in: text) {
            return Text(String(text[..<swiftRange.lowerBound]))
                + Text(String(text[swiftRange])).bold().foregroundStyle(.white)
                + Text(String(text[swiftRange.upperBound...]))
        }
        return Text(text)
    }

    // MARK: - Ending the call

    private var savePrompt: some View {
        VStack(spacing: 20) {
            Text("Do you want to save the\nconversation?")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
            HStack(spacing: 7) {
                Button("No") { finish(save: false) }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.black.opacity(0.11), in: Capsule())
                Button("Yes") { finish(save: true) }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.blue, in: Capsule())
            }
            .font(.system(size: 16, weight: .medium))
        }
        .padding(18)
        .frame(width: 272)
        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
    }

    /// Ends the call, keeping the transcript only if the user asked for it.
    private func finish(save: Bool) {
        showsSavePrompt = false
        if save {
            let segments = conversation
            viewModel.transcriptProvider = { segments }
        } else {
            viewModel.transcriptProvider = nil
        }
        endCall()
    }

    private func sendReply() {
        let message = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, viewModel.callState == .connected else { return }
        // The view model records what was typed and hands it to the engine,
        // which speaks it and sends the exact text.
        viewModel.inputText = message
        viewModel.sendTypedText()
        reply = ""
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// One message bubble in the conversation.
private struct CallBubble: View {
    let text: String
    let isLocal: Bool
    var badge: String? = nil

    var body: some View {
        HStack {
            if isLocal { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true)
                .background(isLocal ? Color.white.opacity(0.84) : Color(red: 159 / 255, green: 159 / 255, blue: 166 / 255), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(alignment: isLocal ? .topLeading : .bottomLeading) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.84), in: Circle())
                            .offset(x: -12, y: isLocal ? -12 : 12)
                    }
                }
            if !isLocal { Spacer(minLength: 40) }
        }
    }
}
