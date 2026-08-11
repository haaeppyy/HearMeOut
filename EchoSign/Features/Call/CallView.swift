import SwiftUI

struct CallView: View {
    @StateObject var viewModel: CallViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    init(viewModel: CallViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.horizontal)

            captionArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))

            typeAndSpeak

            controlBar
        }
        .navigationTitle(viewModel.channelID)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("End call")
            }
        }
        .alert("EchoSign", isPresented: errorBinding) {
            Button(dismissOnAlertOK ? "OK" : "Dismiss", role: .cancel) {
                if dismissOnAlertOK {
                    viewModel.callState = .idle
                    dismiss()
                } else {
                    viewModel.errorMessage = nil
                }
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.callState) { _, newState in
            switch newState {
            case .ended:
                dismiss()
            default:
                break
            }
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Label(viewModel.channelID, systemImage: "number")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            switch viewModel.callState {
            case .connecting:
                Label("Connecting…", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            case .connected:
                if let uid = viewModel.remoteUid {
                    Label("Peer connected (uid \(uid))", systemImage: "person.2.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .ended, .failed, .idle:
                Label("Call ended", systemImage: "phone.down.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding(.vertical, 12)
    }

    // MARK: - Captions

    private var captionArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.captionLog.isEmpty {
                        placeholder
                            .id("empty")
                    } else {
                        ForEach(viewModel.captionLog) { line in
                            captionRow(line)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(16)
            }
            .onChange(of: viewModel.captionLog.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Remote-party captions will appear here once the call connects.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityHidden(true)
    }

    private func captionRow(_ line: CaptionService.CaptionLine) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(line.text.isEmpty ? "…" : line.text)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)

            if !line.isFinal {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.isFinal
                            ? line.text
                            : "Transcribing: \(line.text.isEmpty ? "waiting for speech" : line.text)")
    }

    // MARK: - Type & Speak

    private var typeAndSpeak: some View {
        HStack(spacing: 10) {
            TextField("Type & Speak…", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { viewModel.sendTypedText() }

            Button {
                viewModel.sendTypedText()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel("Send typed message as speech")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.callState == .connected
            && !viewModel.isMuted
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 36) {
            toggleButton(
                systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                tint: viewModel.isMuted ? .red : .blue,
                label: viewModel.isMuted ? "Unmute" : "Mute",
                action: { viewModel.toggleMute() }
            )

            toggleButton(
                systemImage: viewModel.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                tint: viewModel.isSpeakerOn ? .blue : .red,
                label: viewModel.isSpeakerOn ? "Speaker" : "Speaker off",
                action: { viewModel.toggleSpeaker() }
            )

            Button {
                inputFocused = false
                viewModel.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.red, in: Circle())
            }
            .accessibilityLabel("End call")
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func toggleButton(systemImage: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint, in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Alert plumbing

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 && viewModel.errorMessage != nil { viewModel.errorMessage = nil } }
        )
    }

    private var dismissOnAlertOK: Bool {
        if case .failed = viewModel.callState { return true }
        return false
    }
}