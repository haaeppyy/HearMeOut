import Foundation

/// Pure history-reconciliation logic: merges server `call-history` entries
/// into the local recents list. Deliberately free of SwiftUI/GRDB so unit
/// tests can drive every branch deterministically.
///
/// Matching key is `callSessionID` (the backend `callId`):
/// - known rows get their outcome refreshed (status, dates, duration);
/// - unknown rows (incoming calls, calls ended elsewhere, async `missed`
///   from cleanup) are inserted instead of duplicated;
/// - result is sorted newest-first.
enum HistoryMerger {
    static func merge(
        entries: [CallHistoryEntry],
        into recent: [RecentCall],
        contacts: [Contact],
        defaultAudioMode: Bool
    ) -> [RecentCall] {
        var merged = recent
        for entry in entries {
            if let index = merged.firstIndex(where: { $0.callSessionID == entry.callId }) {
                merged[index].didConnect = RecentCall.didConnect(forServerStatus: entry.status)
                if let endedAt = entry.endedAt, let startedAt = entry.startedAt {
                    merged[index].date = startedAt
                    merged[index].duration = max(0, endedAt.timeIntervalSince(startedAt))
                }
            } else {
                let contact = entry.otherPartyId.flatMap { id in contacts.first(where: { $0.remoteUserID == id }) }
                let startedAt = entry.startedAt ?? Date()
                merged.append(RecentCall(
                    contactName: contact?.name ?? "Unknown caller",
                    phoneNumber: contact?.phoneNumber ?? entry.otherPartyId ?? "unknown",
                    callMode: defaultAudioMode ? "audio" : "text",
                    savedConversation: false,
                    transcript: [],
                    contact: contact,
                    date: startedAt,
                    duration: entry.endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } ?? 0,
                    direction: entry.direction == "incoming" ? .incoming : .outgoing,
                    didConnect: RecentCall.didConnect(forServerStatus: entry.status),
                    callSessionID: entry.callId
                ))
            }
        }
        merged.sort { $0.date > $1.date }
        return merged
    }
}
