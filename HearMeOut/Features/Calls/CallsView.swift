import SwiftUI
import UIKit

/// The Calls tab: recent-call history, search, and the entry point for every
/// outgoing call in the app.
///
/// Every call in HearMeOut starts here — the keypad, the contacts list, the
/// search results and the recents rows all funnel through `startCall`,
/// which is the single choke point where the real calling logic plugs in.
///
/// The contacts and the call history both come from the stores; this view
/// never touches the database.
struct CallsView: View {
    let logout: () -> Void
    @EnvironmentObject private var contactsStore: ContactsStore
    @EnvironmentObject private var callHistoryStore: CallHistoryStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var router: CallRouter
    @State private var selectedTab: Tab = .calls
    @State private var selectedCallFilter: CallFilter = .all
    @State private var isShowingFilters = false
    @State private var isShowingProfile = false
    @State private var profileImage: UIImage?
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var selectedRecentCall: RecentCall?
    @State private var inviteTarget: InviteTarget?
    @State private var callErrorMessage: String?

    private var savedContacts: [Contact] { contactsStore.contacts }
    private var recentCalls: [RecentCall] { callHistoryStore.calls }
    private var defaultCallingInterface: String { profileStore.defaultCallingInterface }

    /// Someone who is not on HearMeOut yet.
    private struct InviteTarget: Identifiable {
        let id = UUID()
        let displayName: String
        let phoneNumber: String
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if selectedTab == .contacts {
                    ContactsView(
                        profileImage: profileImage,
                        contacts: savedContacts,
                        onSave: { contactsStore.upsert($0) },
                        onDelete: { contactsStore.delete($0) },
                        onCall: { contact in startCall(to: contact.name, contact: contact) }
                    )
                    .frame(maxHeight: .infinity)
                } else if selectedTab == .keypad {
                    KeypadView(
                        contacts: savedContacts,
                        onSave: { contactsStore.upsert($0) },
                        onCall: { number in
                            if let contact = contactsStore.contact(matching: number) {
                                startCall(to: contact.name, contact: contact)
                            } else {
                                startCall(to: number)
                            }
                        },
                        onInvite: { _, number in
                            inviteTarget = InviteTarget(displayName: number, phoneNumber: number)
                        }
                    )
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
        .fullScreenCover(item: $selectedRecentCall) { call in
            CallDetailView(
                call: call,
                history: recentCalls.filter { $0.phoneNumber == call.phoneNumber },
                redial: { startCall(to: call.contactName, contact: call.contact) },
                saveContact: { contact in
                    contactsStore.upsert(contact)
                    callHistoryStore.link(contact: contact)
                }
            )
        }
        .sheet(item: $inviteTarget) { target in
            InviteSheet(displayName: target.displayName, phoneNumber: target.phoneNumber)
        }
        .alert("Can't place the call", isPresented: Binding(
            get: { callErrorMessage != nil },
            set: { if !$0 { callErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { callErrorMessage = nil }
        } message: {
            Text(callErrorMessage ?? "")
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
            return recentCalls.filter { $0.status.countsAsMissed }
        case .voicemail:
            return recentCalls.filter { !($0.voicemail?.isEmpty ?? true) }
        }
    }

    /// Places a call.
    ///
    /// Everything about how a call is placed — normalising the number,
    /// finding out whether the other person is on HearMeOut at all — lives
    /// in the router, so every entry point behaves the same way.
    private func startCall(to contactName: String, contact: Contact? = nil) {
        let number = contact?.phoneNumber ?? contactName
        Task {
            switch await router.place(number: number, contact: contact) {
            case .started:
                selectedTab = .calls
                isSearching = false
            case .notOnHearMeOut(let displayName):
                inviteTarget = InviteTarget(displayName: displayName, phoneNumber: number)
            case .failed(let message):
                callErrorMessage = message
            }
        }
    }
}

/// Identifies which of the three bottom tabs is showing.
enum Tab: String, CaseIterable {
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
