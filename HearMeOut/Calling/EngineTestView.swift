import SwiftUI

/// Standalone harness for validating the two speech engines without a call:
/// - STT: microphone → `CaptionService` → live transcript.
/// - TTS: text → the exact synthesis/conversion pipeline used in-call, played
///   aloud locally via `SpeakerSink`.
///
/// No backend, no Agora session, no authentication — the fastest way to prove
/// the speech plane works on a device before wiring it into a live call.
///
/// Ported from EchoSign's EngineTestView (no logic changes).
struct EngineTestView: View {
    @StateObject private var viewModel = EngineTestViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusFooter
                sttCard
                ttsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Engine Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - STT card

    private var sttCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Speech-to-Text", systemImage: "waveform.badge.mic")
                .font(.headline)

            Text("Transcribes your microphone on-device. Keep talking past one minute to verify the automatic restart.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                viewModel.toggleListening()
            } label: {
                Label(
                    viewModel.isListening ? "Stop Listening" : "Start Listening",
                    systemImage: viewModel.isListening ? "stop.circle.fill" : "mic.fill"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(viewModel.isListening ? Color.red : Color.accentColor, in: Capsule())
            }
            .accessibilityLabel(viewModel.isListening ? "Stop listening" : "Start listening")

            transcriptList
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptList: some View {
        Group {
            if viewModel.transcriptLines.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                    Text("Transcript will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.transcriptLines) { line in
                        captionRow(line)
                    }
                }
            }
        }
    }

    private func captionRow(_ line: CaptionService.CaptionLine) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(line.text.isEmpty ? "…" : line.text)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !line.isFinal {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - TTS card

    private var ttsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Text-to-Speech", systemImage: "speaker.wave.2.fill")
                .font(.headline)

            Text("Renders typed text through the same pipeline used during calls, then plays it aloud on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !viewModel.voices.isEmpty {
                Picker("Voice", selection: $viewModel.selectedVoiceID) {
                    ForEach(viewModel.voices) { voice in
                        Text(voice.displayName).tag(voice.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("TTS voice")
            }

            if let hint = viewModel.voiceHintText {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField("Type something…", text: $viewModel.ttsInput, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { viewModel.speakTTS() }

            Button {
                viewModel.speakTTS()
            } label: {
                Label(
                    viewModel.isSpeaking ? "Speaking…" : "Speak",
                    systemImage: viewModel.isSpeaking ? "waveform" : "paperplane.fill"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(canSpeak ? Color.accentColor : Color.gray, in: Capsule())
            }
            .disabled(!canSpeak)
            .accessibilityLabel("Speak typed text")

            Button {
                viewModel.speakSanity()
            } label: {
                Label("Speaker sanity (plain)", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .disabled(viewModel.isSpeaking)
            .accessibilityLabel("Speaker sanity check with plain synthesis")

            if !viewModel.ttsStatsText.isEmpty {
                Text(viewModel.ttsStatsText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("TTS pipeline statistics")
            }

            if viewModel.isSpeaking {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var canSpeak: Bool {
        !viewModel.ttsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isSpeaking
    }

    // MARK: - Status / errors

    @ViewBuilder
    private var statusFooter: some View {
        if let error = viewModel.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        } else if let status = viewModel.statusMessage {
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

#Preview {
    NavigationStack {
        EngineTestView()
    }
}
