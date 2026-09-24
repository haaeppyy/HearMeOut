import SwiftUI
import UIKit

struct CallsView: View {
    let logout: () -> Void
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var coordinator: CallCoordinator
    @State private var selectedTab: Tab = .calls
    @State private var selectedCallFilter: CallFilter = .all
    @State private var isShowingFilters = false
    @State private var isShowingProfile = false
    @State private var profileImage: UIImage?
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var savedContacts: [Contact] = []
    @State private var activeAudioCall: ActiveAudioCall?
    @State private var activeTextCall: ActiveTextCall?
    @State private var recentCalls: [RecentCall] = []
    @State private var selectedRecentCall: RecentCall?
    @State private var hasLoadedLocalData = false
    @AppStorage("defaultCallingInterface") private var defaultCallingInterface = "Text Mode"

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if selectedTab == .contacts {
                    ContactsView(profileImage: profileImage, contacts: $savedContacts, startAudioCall: { contact in
                        startCall(to: contact.name, contact: contact)
                    }, coordinator: coordinator)
                        .frame(maxHeight: .infinity)
                } else if selectedTab == .keypad {
                    KeypadView(contacts: $savedContacts, startAudioCall: { number in
                        if let contact = savedContacts.first(where: { $0.phoneNumber == number }) {
                            startCall(to: contact.name, contact: contact)
                        } else {
                            // Free-dialed number with no saved contact: wrap
                            // it transiently so the backend guard chain
                            // (lookup -> "not on Hear Me Out") still applies.
                            startCall(to: number, contact: Contact(name: number, phoneNumber: number, isFavorite: false))
                        }
                    }, coordinator: coordinator)
                        .frame(maxHeight: .infinity)
                } else {
                    header
                        .padding(.top, 8)

                    Spacer()

                    if displayedRecentCalls.isEmpty {
                        EmptyCallsState(defaultCallingInterface: defaultCallingInterface)
                    } else {
                        RecentCallsList(calls: displayedRecentCalls, open: { selectedRecentCall = $0 }) { call in
                            startCall(to: call.contactName, contact: call.contact)
                        }
                    }

                    Spacer()
                }

                if isSearching && selectedTab == .calls {
                    Color.clear.frame(height: 72)
                } else {
                    bottomBar
                        .padding(.horizontal, 15)
                        .padding(.bottom, 8)
                }
            }

            if isSearching && selectedTab == .calls {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissSearch()
                    }

                if !matchingContacts.isEmpty {
                    ContactSearchResults(contacts: matchingContacts) { contact in
                        dismissSearch()
                        startCall(to: contact.name, contact: contact)
                    }
                    .padding(.top, 88)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(1)
                }

                searchBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(1)
            }

            if isShowingFilters {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingFilters = false }

                CallFilterMenu(selection: $selectedCallFilter) {
                    isShowingFilters = false
                }
                .padding(.leading, 24)
                .padding(.top, 76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                .zIndex(2)
            }

            if isShowingProfile {
                ProfileView(profileImage: $profileImage, logout: logout) {
                    isShowingProfile = false
                }
                .transition(.move(edge: .trailing))
                .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isShowingFilters)
        .animation(.easeInOut(duration: 0.24), value: isShowingProfile)
        .fullScreenCover(item: $activeAudioCall) { call in
            AudioCallView(contactName: call.contactName, contact: call.contact) { recordingDuration in
                recentCalls.insert(
                    RecentCall(
                        contactName: call.contactName,
                        phoneNumber: call.contact?.phoneNumber ?? call.contactName,
                        callMode: "audio",
                        savedConversation: false,
                        transcript: [],
                        contact: call.contact,
                        date: call.startedAt,
                        duration: Date().timeIntervalSince(call.startedAt),
                        direction: .outgoing,
                        didConnect: nil,
                        recordingDuration: recordingDuration
                    ),
                    at: 0
                )
                selectedTab = .calls
                isSearching = false
                activeAudioCall = nil
            }
        }
        .fullScreenCover(item: $activeTextCall) { call in
            TextCallView(contactName: call.contactName, contact: call.contact) { result in
                recentCalls.insert(
                    RecentCall(
                        contactName: call.contactName,
                        phoneNumber: call.contact?.phoneNumber ?? call.contactName,
                        callMode: "text",
                        savedConversation: result.savedConversation,
                        transcript: result.transcript,
                        contact: call.contact,
                        date: call.startedAt,
                        duration: Date().timeIntervalSince(call.startedAt),
                        direction: .outgoing,
                        didConnect: result.didConnect
                    ),
                    at: 0
                )
                selectedTab = .calls
                isSearching = false
                activeTextCall = nil
            }
        }
        .fullScreenCover(item: $coordinator.audioRequest) { request in
            AudioCallView(
                contactName: request.contactName,
                contact: request.contact,
                recordingEnabled: false,
                endCall: { _ in coordinator.endViaSystem() },
                activeCall: coordinator.active,
                agora: (coordinator.agora as? AgoraCallManager) ?? AgoraCallManager(),
                callKit: coordinator.callKit as? CallKitManager,
                onEndViaSystem: { coordinator.endViaSystem() },
                duck: coordinator.duck
            )
        }
        .fullScreenCover(item: $coordinator.textRequest) { request in
            TextCallView(
                contactName: request.contactName,
                contact: request.contact,
                finish: { result in
                    coordinator.finishTextCall(transcript: result.transcript, didConnect: result.didConnect)
                },
                coordinator: coordinator,
                channel: coordinator.active.channel
            )
        }
        .fullScreenCover(item: $selectedRecentCall) { call in
            CallDetailView(
                call: call,
                history: recentCalls.filter { $0.phoneNumber == call.phoneNumber },
                redial: { startCall(to: call.contactName, contact: call.contact) },
                saveContact: { contact in
                    if !savedContacts.contains(where: { $0.phoneNumber == contact.phoneNumber }) {
                        savedContacts.append(contact)
                    }
                    for index in recentCalls.indices where recentCalls[index].phoneNumber == call.phoneNumber {
                        recentCalls[index].contact = contact
                        recentCalls[index].contactName = contact.name
                    }
                }
            )
        }
        .onAppear(perform: loadLocalData)
        .task {
            await syncHistoryFromServer()
        }
        .onChange(of: coordinator.linkedContact) { _, linked in
            guard let linked,
                  let index = savedContacts.firstIndex(where: { $0.id == linked.localID })
            else { return }
            savedContacts[index].remoteUserID = linked.remoteID
        }
        .onChange(of: coordinator.finishedCall) { _, finished in
            guard let finished else { return }
            insertFinishedCall(finished)
            coordinator.finishedCall = nil
            Task { await syncHistoryFromServer() }
        }
        .alert("Hear Me Out", isPresented: Binding(
            get: { coordinator.alertMessage != nil },
            set: { if !$0 { coordinator.alertMessage = nil } }
        )) {
            Button("OK") { coordinator.alertMessage = nil }
        } message: {
            Text(coordinator.alertMessage ?? "")
        }
        .onChange(of: savedContacts) { _, _ in
            guard hasLoadedLocalData else { return }
            persistContacts()
        }
        .onChange(of: recentCalls) { _, _ in
            guard hasLoadedLocalData else { return }
            persistCalls()
        }
    }

    private var header: some View {
        ZStack {
            Text("Calls")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.black)

            HStack {
                RoundIconButton(systemName: "line.3.horizontal.decrease", size: 46) {
                    isShowingFilters.toggle()
                }

                Spacer()

                Button {
                    isShowingProfile = true
                } label: {
                    ProfileAvatar(size: 40, image: profileImage)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                TabItem(tab: .calls, selection: $selectedTab)
                TabItem(tab: .contacts, selection: $selectedTab)
                TabItem(tab: .keypad, selection: $selectedTab)
            }
            // The inner content leaves a 4-point glass inset, making the
            // visible capsule exactly 290 × 62 points.
            .frame(width: 282, height: 54)
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.9), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

            Button {
                selectedTab = .calls
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 62, height: 62)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchText)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .background(Color(uiColor: .systemGray5).opacity(0.82), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.55), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)

            Button(action: dismissSearch) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 64)
                    .background(Color(uiColor: .systemGray5).opacity(0.82), in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.55), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        // Focus after the field has been added to the view hierarchy so iOS can
        // present its keyboard reliably.
        .onAppear {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
    }

    private func dismissSearch() {
        isSearchFieldFocused = false
        isSearching = false
        searchText = ""
    }

    private var matchingContacts: [Contact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return savedContacts.filter { !$0.isBlocked && $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var displayedRecentCalls: [RecentCall] {
        switch selectedCallFilter {
        case .all:
            return recentCalls
        case .missed:
            return recentCalls.filter { $0.didConnect == false }
        case .voicemail:
            return recentCalls.filter { !($0.voicemail?.isEmpty ?? true) }
        }
    }

    private func startCall(to contactName: String, contact: Contact? = nil) {
        // Backend path: coordinator owns CallKit + API + media and presents
        // via audioRequest/textRequest below. Local-only path (backend
        // unconfigured or signed out) keeps the original simulated flow.
        if AppConfig.isBackendConfigured, coordinator.auth.isAuthenticated, let contact {
            coordinator.startOutgoing(to: contact, mode: defaultCallingInterface)
            return
        }
        if defaultCallingInterface == "Audio Mode" {
            activeAudioCall = ActiveAudioCall(contactName: contactName, contact: contact)
        } else {
            activeTextCall = ActiveTextCall(contactName: contactName, contact: contact)
        }
    }

    private let localProfileID = "local-profile"

    private func loadLocalData() {
        guard !hasLoadedLocalData else { return }
        do {
            if try database.profiles.fetch() == nil {
                let now = Date()
                try database.profiles.save(LocalProfileRecord(
                    id: localProfileID,
                    remoteUserID: coordinator.auth.userID,
                    name: UserDefaults.standard.string(forKey: "userName") ?? "",
                    phoneNumber: UserDefaults.standard.string(forKey: "userPhoneNumber") ?? "",
                    communicationProfile: UserDefaults.standard.string(forKey: "communicationProfile"),
                    defaultCallingInterface: UserDefaults.standard.string(forKey: "defaultCallingInterface") ?? "Text Mode",
                    profileImageData: nil,
                    hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
                    createdAt: now,
                    updatedAt: now
                ))
            } else if coordinator.auth.isAuthenticated,
                      var existing = try database.profiles.fetch(),
                      existing.remoteUserID == nil,
                      let uid = coordinator.auth.userID {
                // Signed in after the local row was created: backfill the
                // link so history/contact writes stop carrying nil.
                existing.remoteUserID = uid
                existing.updatedAt = Date()
                try database.profiles.save(existing)
            }
            savedContacts = try database.contacts
                .fetchAll(profileID: localProfileID, includingBlocked: true)
                .map(Contact.init(record:))

            let contactsByID = Dictionary(uniqueKeysWithValues: savedContacts.map { ($0.id.uuidString, $0) })
            recentCalls = try database.calls.fetchAll(profileID: localProfileID).map {
                var call = RecentCall(record: $0, contact: $0.contactID.flatMap { contactsByID[$0] })
                if $0.savedConversation {
                    call.transcript = try database.calls
                        .fetchMessages(for: $0.id)
                        .map(\.body)
                }
                return call
            }
            hasLoadedLocalData = true
        } catch {
            // Keep the UI usable, but do not mark the store as loaded. A later
            // appearance can retry after a transient database failure.
            print("Unable to load local data: \(error)")
        }
    }

    private func persistContacts() {
        do {
            try database.contacts.replaceAll(
                savedContacts.map { $0.record(profileID: localProfileID) },
                profileID: localProfileID
            )
        } catch {
            print("Unable to save contacts: \(error)")
        }
    }

    private func persistCalls() {
        do {
            let records = recentCalls.map { call in
                (
                    record: call.record(profileID: localProfileID),
                    messages: call.transcript.enumerated().map { index, text in
                        CallMessageRecord(
                            id: "\(call.id.uuidString)-message-\(index)",
                            recentCallID: call.id.uuidString,
                            sender: "unknown",
                            body: text,
                            sentAt: call.date.addingTimeInterval(TimeInterval(index))
                        )
                    }
                )
            }
            try database.calls.replaceAll(records, profileID: localProfileID)
        } catch {
            print("Unable to save call history: \(error)")
        }
    }

    // MARK: - backend history (Phase 7)

    /// Local GRDB is an offline cache of server truth, not the source of
    /// truth. Backend-finished calls land here with their server callId so
    /// later syncs deduplicate against them instead of duplicating.
    private func insertFinishedCall(_ finished: CallCoordinator.FinishedCall) {
        let contact = finished.contact ?? savedContacts.first(where: { $0.name == finished.contactName })
        recentCalls.insert(
            RecentCall(
                contactName: finished.contactName,
                phoneNumber: contact?.phoneNumber ?? finished.contactName,
                callMode: finished.mode,
                savedConversation: !finished.transcript.isEmpty,
                transcript: finished.transcript,
                contact: contact,
                date: finished.startedAt,
                duration: Date().timeIntervalSince(finished.startedAt),
                direction: .outgoing,
                didConnect: finished.didConnect,
                recordingDuration: finished.recordingDuration,
                callSessionID: finished.callId
            ),
            at: 0
        )
        selectedTab = .calls
        isSearching = false
    }

    private func syncHistoryFromServer() async {
        let entries = await coordinator.fetchHistoryEntries()
        guard !entries.isEmpty else { return }
        mergeHistory(entries)
    }

    /// Merge server entries into the local list. Pure logic lives in
    /// HistoryMerger (unit-tested); this is the @State-writing shell.
    private func mergeHistory(_ entries: [CallHistoryEntry]) {
        recentCalls = HistoryMerger.merge(
            entries: entries,
            into: recentCalls,
            contacts: savedContacts,
            defaultAudioMode: defaultCallingInterface == "Audio Mode"
        )
    }
}

private struct ActiveAudioCall: Identifiable {
    let id = UUID()
    let contactName: String
    let contact: Contact?
    let startedAt = Date()
}

private struct ActiveTextCall: Identifiable {
    let id = UUID()
    let contactName: String
    let contact: Contact?
    let startedAt = Date()
}

/// Call history row. Internal (not private) so HistoryMerger and unit tests
/// can construct and assert on it.
struct RecentCall: Identifiable, Equatable {
    let id: UUID
    var contactName: String
    let phoneNumber: String
    let callMode: String
    let savedConversation: Bool
    var transcript: [String]
    var contact: Contact?
    var date: Date
    var duration: TimeInterval
    let direction: CallDirection
    var didConnect: Bool?
    var voicemail: String? = nil
    var recordingDuration: TimeInterval? = nil
    /// Backend callId for server-synced rows. Nil = local-only row created
    /// before/without the backend. Used to deduplicate history merges.
    var callSessionID: String? = nil

    init(
        id: UUID = UUID(),
        contactName: String,
        phoneNumber: String,
        callMode: String,
        savedConversation: Bool,
        transcript: [String],
        contact: Contact?,
        date: Date,
        duration: TimeInterval,
        direction: CallDirection,
        didConnect: Bool?,
        voicemail: String? = nil,
        recordingDuration: TimeInterval? = nil,
        callSessionID: String? = nil
    ) {
        self.id = id
        self.contactName = contactName
        self.phoneNumber = phoneNumber
        self.callMode = callMode
        self.savedConversation = savedConversation
        self.transcript = transcript
        self.contact = contact
        self.date = date
        self.duration = duration
        self.direction = direction
        self.didConnect = didConnect
        self.voicemail = voicemail
        self.recordingDuration = recordingDuration
        self.callSessionID = callSessionID
    }

    /// Server statuses are richer than the local model: ringing/bridging/
    /// active/created mean "no outcome yet", ended/completed mean connected,
    /// missed/failed mean not.
    static func didConnect(forServerStatus status: String) -> Bool? {
        switch status {
        case "completed", "ended": return true
        case "missed", "failed": return false
        default: return nil
        }
    }
}

extension RecentCall {
    init(record: RecentCallRecord, contact: Contact?) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            contactName: record.contactName,
            phoneNumber: record.contactPhoneNumber,
            callMode: record.callMode,
            savedConversation: record.savedConversation,
            transcript: [],
            contact: contact,
            date: record.createdAt,
            duration: TimeInterval(record.durationSeconds),
            direction: CallDirection(rawValue: record.direction) ?? .outgoing,
            didConnect: record.status == "completed" ? true : (record.status == "missed" ? false : nil),
            recordingDuration: record.recordingDurationSeconds.map(TimeInterval.init),
            callSessionID: record.callSessionID
        )
    }

    func record(profileID: String) -> RecentCallRecord {
        return RecentCallRecord(
            id: id.uuidString,
            profileID: profileID,
            contactID: contact?.id.uuidString,
            callSessionID: callSessionID,
            contactName: contactName,
            contactPhoneNumber: phoneNumber,
            callMode: callMode,
            direction: direction.rawValue,
            status: didConnect == true ? "completed" : (didConnect == false ? "missed" : "ended"),
            startedAt: date,
            endedAt: date.addingTimeInterval(duration),
            durationSeconds: max(0, Int(duration)),
            savedConversation: savedConversation,
            recordingDurationSeconds: recordingDuration.map { max(0, Int($0)) },
            createdAt: date
        )
    }
}

enum CallDirection: String {
    case incoming = "Incoming"
    case outgoing = "Outgoing"
}

private enum CallFilter: String, CaseIterable {
    case all = "All"
    case missed = "Missed calls"
    case voicemail = "Voicemail"

    var icon: String {
        switch self {
        case .all: "phone"
        case .missed: "clock"
        case .voicemail: "recordingtape"
        }
    }
}

private struct CallFilterMenu: View {
    @Binding var selection: CallFilter
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CallFilter.allCases, id: \.self) { filter in
                Button {
                    selection = filter
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        if selection == filter {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 16)
                        }

                        Image(systemName: filter.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18)

                        Text(filter.rawValue)
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == filter ? Color.blue : Color.primary)
                    // Give the longest label enough room to remain on one line,
                    // while preserving the menu's existing row rhythm.
                    .frame(width: 164, height: 41, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemGray5).opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

private struct EmptyCallsState: View {
    let defaultCallingInterface: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: defaultCallingInterface == "Audio Mode" ? "phone.badge.clock.fill" : "text.bubble.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.56))

            Text("No recent calls")
                .font(.system(size: 15))
                .foregroundStyle(Color.secondary.opacity(0.55))

            Text("Your default is \(defaultCallingInterface).")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.55))
        }
    }
}

private struct RecentCallsList: View {
    let calls: [RecentCall]
    let open: (RecentCall) -> Void
    let redial: (RecentCall) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(calls) { call in
                HStack(spacing: 12) {
                    Button { open(call) } label: {
                        HStack(spacing: 12) {
                            ContactCallAvatar(contact: call.contact, fallbackName: call.contactName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(call.contact?.name ?? call.contactName)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.black)
                                Text(call.savedConversation ? "↙ mobile · Conversation saved" : "↙ mobile")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(call.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { redial(call) } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(width: 342, height: 75)
                .background(Color(uiColor: .systemGray5).opacity(0.9), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 30)
    }
}

private struct CallDetailView: View {
    let call: RecentCall
    let history: [RecentCall]
    let redial: () -> Void
    let saveContact: (Contact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contact: Contact?
    @State private var isAddingContact = false
    @State private var isShowingContactCard = false
    @State private var showsSavedItem = false

    init(call: RecentCall, history: [RecentCall], redial: @escaping () -> Void, saveContact: @escaping (Contact) -> Void) {
        self.call = call
        self.history = history
        self.redial = redial
        self.saveContact = saveContact
        _contact = State(initialValue: call.contact)
    }

    private var durationText: String {
        let seconds = max(0, Int(call.duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var hasSavedItem: Bool {
        !(call.voicemail?.isEmpty ?? true) || call.recordingDuration != nil || call.savedConversation
    }

    private var actionSize: CGFloat { 48 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ContactCallAvatar(contact: contact, fallbackName: call.contactName, size: 112)
                        .frame(width: 112, height: 112)
                        .padding(.top, 70)
                    Text(contact?.name ?? call.contactName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.top, 18)
                    if let contact {
                        Text(contact.phoneNumber)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                    }

                    HStack(spacing: 72) {
                        detailAction(symbol: "phone", title: "Call", action: redialCall)
                        if contact != nil {
                            detailAction(symbol: "person.crop.circle", title: "Contact Card") {
                                isShowingContactCard = true
                            }
                        } else {
                            detailAction(symbol: "person.crop.circle.badge.plus", title: "Add Contact") {
                                isAddingContact = true
                            }
                        }
                    }
                    .padding(.top, 22)

                    callSummaryCard
                        .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Call History")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                        callHistoryCard
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
            }
            CircleActionButton(symbol: "chevron.left") { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 28)
                .padding(.top, 14)

            if isAddingContact {
                NewContactView(
                    initialPhoneNumber: contact?.phoneNumber ?? call.contactName,
                    cancel: { isAddingContact = false },
                    save: { newContact in
                        saveContact(newContact)
                        contact = newContact
                        isAddingContact = false
                    }
                )
                .transition(.move(edge: .trailing))
            }

            if isShowingContactCard, let contact {
                contactCardOverlay(contact)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if showsSavedItem {
                savedItemOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isAddingContact)
        .animation(.easeInOut(duration: 0.22), value: isShowingContactCard)
        .animation(.easeInOut(duration: 0.22), value: showsSavedItem)
    }

    private var callSummaryCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(call.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 14, weight: .regular))
                Spacer()
                Text(call.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .regular))
            }
            HStack(spacing: 5) {
                Text(call.direction.rawValue)
                if let didConnect = call.didConnect {
                    Text("·")
                    Text(didConnect ? durationText : "Didn’t connect")
                } else {
                    Text("·")
                    Text(durationText)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.top, 4)

            if hasSavedItem {
                Divider().padding(.top, 13)
                HStack(spacing: 10) {
                    if !(call.voicemail?.isEmpty ?? true) {
                        savedContentAction(symbol: "recordingtape", title: "Voicemail", duration: nil)
                    }
                    if let recordingDuration = call.recordingDuration {
                        savedContentAction(symbol: "record.circle", title: "Call recording", duration: recordingDuration)
                    }
                    if call.savedConversation {
                        savedContentAction(symbol: "text.bubble", title: "Saved conversation", duration: nil)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.top, 7)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 353, height: hasSavedItem ? 149 : 84)
        .background(Color(uiColor: .systemGray5).opacity(0.88), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var callHistoryCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(history.sorted { $0.date > $1.date }.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 14, weight: .regular))
                        HStack(spacing: 5) {
                            Text(entry.direction.rawValue)
                            if let didConnect = entry.didConnect {
                                Text("·")
                                Text(didConnect ? durationText(for: entry.duration) : "Didn’t connect")
                            } else {
                                Text("·")
                                Text(durationText(for: entry.duration))
                            }
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 14, weight: .regular))
                        if entry.savedConversation {
                            Label("Saved conversation", systemImage: "text.bubble")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if entry.recordingDuration != nil {
                            Label("Saved Call", systemImage: "record.circle")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if !(entry.voicemail?.isEmpty ?? true) {
                            Label("Voicemail", systemImage: "recordingtape")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 12)
                if index < history.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 353)
        .background(Color(uiColor: .systemGray5).opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailAction(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.black)
                    .frame(width: actionSize, height: actionSize)
                    .background(Color(uiColor: .systemGray4).opacity(0.55), in: Circle())
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.black)
            }
            .frame(minWidth: 92)
        }
        .buttonStyle(.plain)
    }

    private func savedContentAction(symbol: String, title: String, duration: TimeInterval?) -> some View {
        Button { showsSavedItem = true } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .regular)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let duration {
                    Text(humanDuration(duration))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func contactCardOverlay(_ contact: Contact) -> some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { isShowingContactCard = false }
            VStack(spacing: 14) {
                ContactCallAvatar(contact: contact, fallbackName: contact.name, size: 72)
                Text(contact.name).font(.system(size: 20, weight: .semibold))
                Text(contact.phoneNumber).font(.system(size: 15)).foregroundStyle(.secondary)
                Button("Done") { isShowingContactCard = false }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 280)
            .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private var savedItemOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { showsSavedItem = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(savedItemTitle).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button { showsSavedItem = false } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                    }
                }
                if call.savedConversation {
                    ForEach(Array(call.transcript.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 15))
                    }
                } else if let voicemail = call.voicemail, !voicemail.isEmpty {
                    Text(voicemail).font(.system(size: 15))
                } else if let recordingDuration = call.recordingDuration {
                    Text("\(durationText(for: recordingDuration)) recording")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 300, alignment: .leading)
            .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var savedItemTitle: String {
        if call.savedConversation { return "Saved conversation" }
        if call.recordingDuration != nil { return "Call recording" }
        return "Voicemail"
    }

    private func durationText(for duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func humanDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder) sec" }
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }

    private func redialCall() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: redial)
    }
}

private struct ContactSearchResults: View {
    let contacts: [Contact]
    let call: (Contact) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(contacts) { contact in
                HStack(spacing: 12) {
                    ContactCallAvatar(contact: contact, fallbackName: contact.name)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.name)
                            .font(.system(size: 16, weight: .medium))
                        Text(contact.phoneNumber)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button { call(contact) } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(width: 342, height: 75)
                .background(Color(uiColor: .systemGray5).opacity(0.96), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
    }
}

private struct ContactCallAvatar: View {
    let contact: Contact?
    let fallbackName: String
    var size: CGFloat = 48

    private var initials: String {
        let parts = fallbackName.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "?" }
        guard let last = parts.dropFirst().last?.first else { return String(first).uppercased() }
        return "\(String(first).uppercased())\(String(last).uppercased())"
    }

    var body: some View {
        Group {
            if let data = contact?.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ProfileAvatar.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private enum Tab: String, CaseIterable {
    case calls = "Calls"
    case contacts = "Contacts"
    case keypad = "Keypad"

    var icon: String {
        switch self {
        case .calls: "phone.fill"
        case .contacts: "person.3.fill"
        case .keypad: "circle.grid.3x3.fill"
        }
    }
}

private struct TabItem: View {
    let tab: Tab
    @Binding var selection: Tab

    var body: some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(tab == .contacts ? .monochrome : .hierarchical)
                Text(tab.rawValue)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(selection == tab ? Color.blue : Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                if selection == tab {
                    Capsule().fill(Color.white.opacity(0.88))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RoundIconButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: systemName == "person.fill" ? 20 : 19, weight: .medium))
                .foregroundStyle(systemName == "person.fill" ? .white : .black)
                .frame(width: size, height: size)
                .background {
                    if systemName == "person.fill" {
                        Circle().fill(ProfileAvatar.gradient)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

#Preview {
    CallsView(logout: { })
}
