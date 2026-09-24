import SwiftUI

/// Local-only Text Mode UI; no messages or call data are transmitted.
struct TextCallView: View {
    let contactName: String
    var contact: Contact? = nil
    let finish: (TextCallResult) -> Void
    /// Backend wiring (Phase 6 + speech plane). Always observed (dummy graph
    /// by default so previews/legacy covers compile); backend behavior gates
    /// on `channel != nil`, never on the coordinator's presence.
    @ObservedObject var coordinator: CallCoordinator = CallCoordinator(
        auth: SupabaseAuthManager(),
        active: ActiveCall(),
        callKit: CallKitManager(),
        pushKit: PushKitManager(),
        agora: AgoraCallManager()
    )
    var channel: String? = nil

    @State private var isConnected = false
    @State private var callConnectedAt: Date?
    @State private var showsAudioInterface = false
    @State private var reply = ""
    @State private var sentReplies: [String] = []
    @State private var incomingMessages: [String] = []
    @State private var showsSavePrompt = false
    @State private var seenIncomingIDs: Set<UUID> = []
    @FocusState private var isReplyFocused: Bool

    /// Backend calls are "connected" once ActiveCall records a connection;
    /// local mode (no channel) keeps its simulated flag.
    private var connected: Bool {
        if channel != nil { return coordinator.active.connectedAt != nil }
        return isConnected
    }

    var body: some View {
        ZStack {
            if showsAudioInterface {
                AudioCallView(
                    contactName: contactName,
                    contact: contact,
                    callConnectedAt: callConnectedAt,
                    recordingEnabled: false,
                    showTextMode: { showsAudioInterface = false },
                    endCall: { _ in showsSavePrompt = true },
                    // Same live session — toggling UI must not rejoin media.
                    // The coordinator holds these as protocol existentials
                    // (see *Driving.swift); the views still take the concrete
                    // managers for @ObservedObject. Production graphs always
                    // build the coordinator from concretes, so these casts
                    // succeed — the fallbacks never fire.
                    activeCall: coordinator.active,
                    agora: (coordinator.agora as? AgoraCallManager) ?? AgoraCallManager(),
                    callKit: coordinator.callKit as? CallKitManager,
                    duck: coordinator.duck
                )
                .blur(radius: showsSavePrompt ? 5 : 0)
            } else {
                textInterface
            }

            if showsSavePrompt { savePrompt }
        }
        .onAppear {
            // Local-only mode fakes "connecting" with a timer. Backend calls
            // connect via ActiveCall.connectedAt instead — never fake it.
            guard channel == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if callConnectedAt == nil {
                    callConnectedAt = Date()
                    isConnected = true
                }
            }
        }
        .onChange(of: coordinator.incomingTexts.count) { _, _ in
            mergeIncomingTexts()
        }
    }

    /// Append newly arrived RTM messages for this call's channel.
    private func mergeIncomingTexts() {
        guard let channel else { return }
        for item in coordinator.incomingTexts where item.channel == channel && !seenIncomingIDs.contains(item.id) {
            seenIncomingIDs.insert(item.id)
            incomingMessages.append(item.text)
        }
    }

    private var textInterface: some View {
        ZStack {
            Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if connected {
                    ScrollView(showsIndicators: false) {
                        ConversationBubbles(sentReplies: sentReplies, incomingMessages: incomingMessages)
                            .padding(.top, 30)
                            .padding(.bottom, 22)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 22)
                }
                liveCaptions
                composer.padding(.bottom, 28)
            }
            .blur(radius: showsSavePrompt ? 5 : 0)

        }
        .preferredColorScheme(.dark)
    }

    /// Live STT captions of what the other party is saying (backend calls
    /// only). RTM bubbles above are what was typed; these are what was heard.
    private var liveCaptions: some View {
        Group {
            if channel != nil, !coordinator.captionLines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LIVE CAPTIONS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(coordinator.captionLines.suffix(3)) { line in
                        Text(line.text.isEmpty ? "…" : line.text)
                            .font(.system(size: 15))
                            .foregroundStyle(line.isFinal ? .white : .white.opacity(0.55))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                CallDurationLabel(connectedAt: callConnectedAt)
                Text(contactName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }

            HStack {
                Button { showsAudioInterface = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                        Image(systemName: "speaker.wave.2").font(.system(size: 24, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(width: 78, height: 48)
                }
                .buttonStyle(.plain)
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
                    Text("End").font(.system(size: 16)).foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 26)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $reply,
                prompt: Text("enter ur reply here")
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
        }
        .padding(.leading, 20)
        .padding(.trailing, 7)
        .frame(width: 346, height: 57)
        .background(Color(red: 220 / 255, green: 220 / 255, blue: 225 / 255), in: Capsule())
    }

    private var savePrompt: some View {
        VStack(spacing: 20) {
            Text("Do you want to save the\nconversation?")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
            HStack(spacing: 7) {
                Button("No") { finish(TextCallResult(savedConversation: false, didConnect: connected)) }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.black.opacity(0.11), in: Capsule())
                Button("Yes") {
                    finish(TextCallResult(savedConversation: true, transcript: transcript, didConnect: connected))
                }
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

    private func sendReply() {
        let message = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard channel != nil else {
            sentReplies.append(message)
            reply = ""
            return
        }
        // Backend mode — Type & Speak: the text is synthesized into the
        // outgoing call audio (what the hearing party hears) AND published
        // over RTM as the read-backup. Append on RTM ack only, never before.
        reply = ""
        Task {
            do {
                try await coordinator.speakAndSend(message)
                sentReplies.append(message)
            } catch {
                // Delivery failed: put the text back so nothing is lost.
                reply = message
            }
        }
    }

    private var transcript: [String] {
        incomingMessages + sentReplies
    }

}

struct TextCallResult {
    let savedConversation: Bool
    var transcript: [String] = []
    var didConnect: Bool = false
}

private struct ConversationBubbles: View {
    let sentReplies: [String]
    let incomingMessages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(incomingMessages, id: \.self) { message in
                CallBubble(text: message, isLocal: false, badge: "person.fill")
            }
            ForEach(sentReplies, id: \.self) { message in
                CallBubble(text: message, isLocal: true)
            }
        }
        .padding(.horizontal, 36)
    }
}

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

#Preview { TextCallView(contactName: "John Doe", finish: { _ in }) }
