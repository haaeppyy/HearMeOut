import Foundation

/// A channel for sending exact text to the other side of a call.
///
/// The rest of the app only deals with text; how the text travels sits
/// behind this protocol. Today it is an Agora data stream, riding the same
/// connection as the audio. If that turns out not to work on a device, it
/// can be swapped for Supabase Realtime Broadcast without anything above
/// this line changing.
protocol TextChannel: AnyObject {
    /// Whether the channel is ready to carry text.
    var isReady: Bool { get }

    /// Opens the channel for a call.
    func open()

    /// Sends text to the other side.
    ///
    /// Returns `false` when the text could not be sent — the caller decides
    /// whether that is worth telling the user about.
    @discardableResult
    func send(_ text: String) -> Bool

    /// Closes the channel.
    func close()

    /// Called when text arrives from the other side.
    var onText: ((String) -> Void)? { get set }
}

/// Sends exact text over an Agora RTC data stream.
///
/// This is the same connection the audio rides, so there is nothing extra
/// to set up and nothing extra for the server to know about.
final class AgoraDataStreamTextChannel: TextChannel {

    private let agora: AgoraService

    var onText: ((String) -> Void)?

    var isReady: Bool { agora.isTextStreamOpen }

    init(agora: AgoraService) {
        self.agora = agora
        agora.onDataStreamMessage = { [weak self] text in
            self?.onText?(text)
        }
    }

    func open() {
        agora.openTextStream()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        agora.sendText(text)
    }

    func close() {
        agora.closeTextStream()
    }
}
