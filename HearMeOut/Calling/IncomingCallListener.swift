import Foundation
import Supabase

/// Foreground incoming-call delivery for environments without PushKit (most
/// importantly the iOS Simulator). The server still remains authoritative:
/// this only observes rows the authenticated callee is allowed to read.
///
/// It listens for two things. A new call, which is the one that has to
/// ring. And a change to a call that was ringing — the caller hung up, or
/// it was answered somewhere else — so the ringing UI can be taken down
/// instead of sitting there for a call that is already over.
@MainActor
final class IncomingCallListener {
    struct IncomingCall: Identifiable, Decodable {
        let id: UUID
        let callerID: UUID
        /// The caller's name at the time of the call, snapshotted onto the
        /// call row by the server.
        let callerDisplayName: String?
        /// The caller's phone number, for the same reason.
        let callerPhone: String?
        let createdAt: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case id
            case callerID = "caller_id"
            case callerDisplayName = "caller_display_name"
            case callerPhone = "caller_phone"
            case createdAt = "created_at"
            case status
        }

        /// Whether this call is still ringing.
        var isRinging: Bool { status == "ringing" }
    }

    /// A call has started ringing.
    var onIncomingCall: ((IncomingCall) -> Void)?

    /// A call that was ringing is no longer ringing.
    var onCallStoppedRinging: ((UUID) -> Void)?

    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var listenerTask: Task<Void, Never>?
    private var currentUserID: UUID?

    init(client: SupabaseClient) {
        self.client = client
    }

    func start(for userID: UUID) {
        guard currentUserID != userID || channel == nil else {
            catchUp()
            return
        }
        stop()
        currentUserID = userID

        let channel = client.channel("incoming-calls-\(userID.uuidString)")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "calls",
            filter: .eq("callee_id", value: userID)
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "calls",
            filter: .eq("callee_id", value: userID)
        )
        self.channel = channel

        listenerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.subscribeWithError()
                self.catchUp()
                // Both streams have to be drained at the same time: a call
                // that starts ringing and is then cancelled arrives as an
                // insert followed by an update.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor [weak self] in
                        for await insertion in inserts {
                            guard let call = try? Self.decode(insertion) else { continue }
                            self?.onIncomingCall?(call)
                        }
                    }
                    group.addTask { @MainActor [weak self] in
                        for await update in updates {
                            guard let call = try? Self.decode(update) else { continue }
                            self?.handleUpdate(call)
                        }
                    }
                }
            } catch {
                // Realtime reconnects managed channels itself. The catch-up
                // query also runs whenever the app returns to foreground.
                print("[IncomingCallListener] subscription failed: \(error.localizedDescription)")
            }
        }
    }

    func catchUp() {
        guard let currentUserID else { return }
        Task { [weak self] in
            guard let self else { return }
            let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-45))
            do {
                let calls: [IncomingCall] = try await client
                    .from("calls")
                    .select("id, caller_id, caller_display_name, caller_phone, created_at, status")
                    .eq("callee_id", value: currentUserID.uuidString)
                    .eq("status", value: "ringing")
                    .gte("created_at", value: since)
                    .execute()
                    .value
                calls.forEach { self.onIncomingCall?($0) }
            } catch {
                print("[IncomingCallListener] catch-up failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        if let channel {
            Task { await client.removeChannel(channel) }
        }
        channel = nil
        currentUserID = nil
    }

    /// A call that was ringing has stopped ringing.
    private func handleUpdate(_ call: IncomingCall) {
        guard !call.isRinging else { return }
        onCallStoppedRinging?(call.id)
    }

    // Decoding is pure, so it does not need the main actor even though the
    // listener itself lives there.
    nonisolated private static func decode(_ insertion: InsertAction) throws -> IncomingCall {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try insertion.decodeRecord(as: IncomingCall.self, decoder: decoder)
    }

    nonisolated private static func decode(_ update: UpdateAction) throws -> IncomingCall {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try update.decodeRecord(as: IncomingCall.self, decoder: decoder)
    }
}
