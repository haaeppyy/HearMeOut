import AVFoundation
import Combine
import Foundation
import Speech

/// Live captions driven by one of two audio sources:
///
/// - `.remote` (default): consumes the remote party's PCM playback frames that
///   `AgoraService` forwards here. This is the product goal — captioning the
///   other speaker — and it keeps the audio session exclusively owned by Agora.
/// - `.local`: taps the on-device microphone via `AVAudioEngine`. Intended mainly
///   for offline testing; while an Agora call is active the two audio paths
///   compete for the same hardware, so `.remote` is the safe default.
///
/// Both paths use `SFSpeechAudioBufferRecognitionRequest`. On-device recognition
/// caps each recognition task at roughly one minute, so the task is restarted
/// seamlessly on a timer.
final class CaptionService: NSObject, ObservableObject {

    override init() {
        super.init()
    }

    enum Source: String, CaseIterable, Identifiable {
        case remote
        case local

        var id: String { rawValue }
    }

    struct CaptionLine: Identifiable, Equatable {
        let id: UUID
        let text: String
        let isFinal: Bool

        init(id: UUID = UUID(), text: String, isFinal: Bool) {
            self.id = id
            self.text = text
            self.isFinal = isFinal
        }
    }

    enum CaptionError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition isn't available on this device right now."
            }
        }
    }

    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var source: Source = .remote
    @Published private(set) var isListening = false

    /// Surfaced to the view model when recognition stops unexpectedly.
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?

    /// Accessed on the main thread for create/endAudio, and on the audio ingest
    /// queues for append (the pattern Apple's own samples use for mic taps).
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var restartTimer: Timer?
    private let captureQueue = DispatchQueue(label: "echo.captions.capture", qos: .userInitiated)

    // On-device requests are capped at ~1 minute; restart just before then.
    private static let restartInterval: TimeInterval = 55

    // MARK: - Permissions & availability

    /// Requests all permissions/preconditions once, before any call starts.
    /// Returns `false` (and posts to `onError`) when captions can't run.
    func prepare() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else {
                onError?("Speech recognition access is required for captions.")
                return false
            }
        case .denied, .restricted:
            onError?("Speech recognition access is required for captions. You can enable it in Settings.")
            return false
        @unknown default:
            return false
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                onError?("Microphone access is required for captions. You can enable it in Settings.")
                return false
            }
        case .denied:
            onError?("Microphone access is required for captions. You can enable it in Settings.")
            return false
        @unknown default:
            return false
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            onError?(CaptionError.recognizerUnavailable.localizedDescription)
            return false
        }
        self.recognizer = recognizer
        recognizer.delegate = self
        return true
    }

    // MARK: - Lifecycle

    func setSource(_ newSource: Source) {
        guard newSource != source else { return }
        if isListening {
            stop()
            source = newSource
            start()
        } else {
            source = newSource
        }
    }

    func start() {
        guard !isListening, recognizer != nil else { return }
        isListening = true
        lines.removeAll(keepingCapacity: true)

        if source == .local {
            startLocalCapture()
        }
        startRecognitionTask()
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        if let request = recognitionRequest {
            request.endAudio()
        }
        recognitionRequest = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        isListening = false
    }

    func clear() {
        lines.removeAll()
    }

    // MARK: - Audio ingestion

    /// Feed for the `.remote` source. Runs on Agora's audio thread; the heavy
    /// work (wrapping + appending) is moved to the capture queue.
    func appendRemotePCM(pointer: UnsafeMutablePointer<Int16>, samplesPerChannel: Int, channels: Int) {
        guard source == .remote else { return }

        let ch = channels > 0 ? channels : 1
        let count = samplesPerChannel * ch
        guard count > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(AgoraService.sampleRate),
                  channels: AVAudioChannelCount(ch),
                  interleaved: true
              )
        else { return }

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        guard let buffer else { return }
        buffer.frameLength = AVAudioFrameCount(count)

        if let dst = buffer.int16ChannelData?[0] {
            dst.update(from: pointer, count: count)
        }

        captureQueue.async { [weak self] in
            self?.recognitionRequest?.append(buffer)
        }
    }

    /// Feed for the `.local` source (microphone tap).
    private func startLocalCapture() {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    // MARK: - Recognition task

    private func startRecognitionTask() {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            // Keep audio on-device; also makes the ~1-minute session limit relevant.
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // Seed an in-flight line so partial results have somewhere to land.
        lines.append(CaptionLine(text: "", isFinal: false))

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    // 216 = task canceled. We cancel tasks ourselves on restart,
                    // so treat it as a normal teardown, not a failure.
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        return
                    }
                    self.onError?(error.localizedDescription)
                    self.stop()
                }
                return
            }
            guard let result else { return }
            DispatchQueue.main.async {
                self.digest(result)
            }
        }

        scheduleRestart()
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restartRecognitionTask()
        }
    }

    /// Seamlessly end the current task and open a new one so 60+ second calls
    /// keep transcribing. Capture taps/feeds keep targeting `recognitionRequest`.
    private func restartRecognitionTask() {
        guard isListening else { return }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        startRecognitionTask()
    }

    private func digest(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString

        if result.isFinal {
            if let last = lines.last, !last.isFinal {
                lines[lines.count - 1] = CaptionLine(id: last.id, text: text, isFinal: true)
            } else {
                lines.append(CaptionLine(text: text, isFinal: true))
            }
        } else if let last = lines.last, !last.isFinal {
            lines[lines.count - 1] = CaptionLine(id: last.id, text: text, isFinal: false)
        }

        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension CaptionService: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async {
            if !available && self.isListening {
                self.onError?("Speech recognition became unavailable.")
                self.stop()
            }
        }
    }
}