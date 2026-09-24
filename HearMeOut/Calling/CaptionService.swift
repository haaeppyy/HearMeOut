import AVFoundation
import Combine
import Foundation
import Speech

/// Live captions driven by one of two audio sources:
///
/// - `.remote` (default): consumes the remote party's PCM playback frames that
///   `AgoraCallManager` forwards here. This is the product goal — captioning the
///   other speaker — and it keeps the audio session exclusively owned by Agora.
/// - `.local`: taps the on-device microphone via `AVAudioEngine`. Intended mainly
///   for offline testing (EngineTestView); while an Agora call is active the two
///   audio paths compete for the same hardware, so `.remote` is the safe default.
///
/// Both paths use `SFSpeechAudioBufferRecognitionRequest`. On-device recognition
/// caps each recognition task at roughly one minute, so the task is restarted
/// seamlessly on a timer.
///
/// Ported from EchoSign's CaptionService; the only change is the sample-rate
/// source (`AgoraCallManager.sampleRate` instead of `AgoraService.sampleRate`).
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

    /// Surfaced to the coordinator when recognition stops unexpectedly.
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?

    /// Accessed on the main thread for create/endAudio, and on the audio ingest
    /// queues for append (the pattern Apple's own samples use for mic taps).
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Identifies the live recognition task; events from superseded tasks
    /// (cancelled during a restart) are dropped by ID instead of corrupting
    /// state or stopping a fresh session.
    private var currentTaskID: UUID?

    private var restartTimer: Timer?
    private let captureQueue = DispatchQueue(label: "hearmeout.captions.capture", qos: .userInitiated)

    // On-device requests are capped at ~1 minute; restart just before then.
    private static let restartInterval: TimeInterval = 55

    // MARK: - Helpers

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// All error reporting funnels through here so subscribers can assume main.
    private func reportError(_ message: String) {
        onMain { self.onError?(message) }
    }

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
            reportError("Speech recognition access is required for captions. You can enable it in Settings.")
            return false
        @unknown default:
            return false
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                reportError("Microphone access is required for captions. You can enable it in Settings.")
                return false
            }
        case .denied:
            reportError("Microphone access is required for captions. You can enable it in Settings.")
            return false
        @unknown default:
            return false
        }

        // `prepare` may resume off-main (authorization continuation); keep
        // recognizer state and its delegate assignment on the main thread.
        let recognizerAvailable: Bool = await MainActor.run {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
                self.reportError(CaptionError.recognizerUnavailable.localizedDescription)
                return false
            }
            self.recognizer = recognizer
            recognizer.delegate = self
            print("[Captions] recognizer ready: en-US on-device=\(recognizer.supportsOnDeviceRecognition)")
            return true
        }
        return recognizerAvailable
    }

    // MARK: - Lifecycle

    // Lifecycle entry points hop to main: `prepare()` can resume off-main, and
    // a background-thread `start` would schedule the restart Timer on a runloop
    // that never runs — captions would silently die at the ~60 s task limit.

    func setSource(_ newSource: Source) {
        onMain {
            guard newSource != self.source else { return }
            if self.isListening {
                self.stopInternal()
                self.source = newSource
                self.startInternal()
            } else {
                self.source = newSource
            }
        }
    }

    func start() {
        onMain { self.startInternal() }
    }

    func stop() {
        onMain { self.stopInternal() }
    }

    private func startInternal() {
        guard !isListening, recognizer != nil else { return }
        isListening = true
        lines.removeAll(keepingCapacity: true)

        if source == .local {
            startLocalCapture()
        }
        startRecognitionTaskInternal()
    }

    private func stopInternal() {
        restartTimer?.invalidate()
        restartTimer = nil

        currentTaskID = nil
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
    /// work (conversion + appending) is moved to the capture queue.
    ///
    /// Agora hands over 16 kHz Int16-interleaved frames; the recognizer is fed
    /// standard Float32 buffers (the Apple-sample pattern) — some iOS builds
    /// silently produce zero recognition results from Int16 input.
    func appendRemotePCM(pointer: UnsafeMutablePointer<Int16>, samplesPerChannel: Int, channels: Int) {
        guard source == .remote else { return }

        let channelCount = max(channels, 1)
        let frames = samplesPerChannel
        let totalSamples = frames * channelCount
        guard frames > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: Double(AgoraCallManager.sampleRate),
                  channels: AVAudioChannelCount(channelCount)
              )
        else { return }

        // Conversion + deinterleave live in AudioFramePipeline (unit-tested);
        // this path only moves the planar result into the recognizer buffer.
        let planar = AudioFramePipeline.deinterleaveToPlanar(
            pointer: pointer, frames: frames, channelCount: channelCount
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        if let channelData = buffer.floatChannelData {
            for c in 0..<channelCount {
                for i in 0..<frames {
                    channelData[c][i] = planar[c][i]
                }
            }
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
            reportError("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    // MARK: - Recognition task

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if let recognizer, recognizer.supportsOnDeviceRecognition {
            // Keep audio on-device; also makes the ~1-minute session limit relevant.
            request.requiresOnDeviceRecognition = true
        }
        return request
    }

    private func makeTask(with request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechRecognitionTask {
        guard let recognizer else {
            fatalError("makeTask called without a recognizer")
        }

        let taskID = UUID()
        currentTaskID = taskID

        // Seed an in-flight line so partial results have somewhere to land.
        lines.append(CaptionLine(text: "", isFinal: false))

        return recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                // Events from a superseded task (cancelled during restart or
                // stop) must not touch the current session's state.
                guard self.currentTaskID == taskID else { return }

                if let error {
                    // 216 = task canceled. We cancel tasks ourselves on restart,
                    // so treat it as a normal teardown, not a failure.
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        return
                    }
                    self.reportError(error.localizedDescription)
                    self.stopInternal()
                    return
                }
                guard let result else { return }
                self.digest(result)
            }
        }
    }

    private func startRecognitionTaskInternal() {
        guard recognizer != nil else { return }
        let request = makeRecognitionRequest()
        recognitionRequest = request
        recognitionTask = makeTask(with: request)
        scheduleRestartTimer()
    }

    private func scheduleRestartTimer() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restartRecognitionTask()
        }
    }

    /// Seamlessly end the current task and open a new one so 60+ second calls
    /// keep transcribing. The new request is armed *before* the old task is
    /// cancelled, so capture feeds never target a dead request and no audio is
    /// lost at the boundary.
    private func restartRecognitionTask() {
        guard isListening, recognizer != nil else { return }

        let newRequest = makeRecognitionRequest()
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask

        recognitionRequest = newRequest
        recognitionTask = makeTask(with: newRequest)

        oldTask?.cancel()
        oldRequest?.endAudio()

        scheduleRestartTimer()
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
                self.reportError("Speech recognition became unavailable.")
                self.stopInternal()
            }
        }
    }
}
