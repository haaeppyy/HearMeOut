import SwiftUI

/// The Keypad tab: type a number, see whether that number is on HearMeOut,
/// and start a call.
///
/// The chip under the number answers "is this person on HearMeOut?" without
/// the user having to place a call first and wait for nothing to happen.
/// The lookup is debounced, so typing a number does not fire a request per
/// keystroke.
struct KeypadView: View {
    let contacts: [Contact]
    /// Saves a contact created from the keypad.
    let onSave: (Contact) -> Void
    /// Starts a call to the number dialled.
    let onCall: (String) -> Void
    /// Offers to invite someone who is not on HearMeOut yet.
    let onInvite: (String, String) -> Void

    @EnvironmentObject private var router: CallRouter
    @EnvironmentObject private var contactsStore: ContactsStore
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var enteredNumber = ""
    @State private var isShowingNewContact = false
    @State private var lookup: LookupState = .none
    @State private var lookupTask: Task<Void, Never>?

    /// What the chip under the number is showing.
    private enum LookupState: Equatable {
        /// Nothing to show — the number is not a complete number yet.
        case none
        /// A lookup is in flight. The chip stays blank rather than
        /// flickering a spinner on every keystroke.
        case checking
        case registered
        case notOnApp
        /// The server could not be reached.
        case failed
        /// The user dialled their own number.
        case ownNumber
    }

    private let keys: [(number: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", ""), ("#", "")
    ]

    private var matchingContacts: [Contact] {
        guard !enteredNumber.isEmpty else { return [] }
        let key = PhoneNumber.matchingKey(enteredNumber)
        return contacts.filter { contact in
            guard !contact.isBlocked else { return false }
            return contact.normalizedPhone.contains(key) ||
                contact.name.t9Digits.contains(enteredNumber)
        }
    }

    /// Whether the number typed so far could be a complete phone number.
    private var isCompleteNumber: Bool {
        (try? PhoneNumber.normalize(enteredNumber)) != nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { isShowingNewContact = true } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(enteredNumber.isEmpty ? Color.secondary.opacity(0.4) : Color.black)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .disabled(enteredNumber.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer(minLength: 18)

                VStack(spacing: 8) {
                    ForEach(matchingContacts.prefix(3)) { contact in
                        Button {
                            enteredNumber = contact.phoneNumber
                        } label: {
                            HStack(spacing: 11) {
                                ContactAvatar(contact: contact, size: 38)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(contact.name.t9Digits.contains(enteredNumber) ? Color.blue : Color.primary)
                                    highlightedPhoneNumber(contact.phoneNumber)
                                        .font(.system(size: 14, weight: .medium))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 70)

                Text(enteredNumber)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(height: 43)

                chip
                    .frame(height: 24)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(80), spacing: 20), count: 3),
                    spacing: 20
                ) {
                    ForEach(keys, id: \.number) { key in
                        KeypadButton(
                            number: key.number,
                            letters: key.letters,
                            longPress: key.number == "0" ? { enteredNumber.append("+") } : nil
                        ) {
                            enteredNumber.append(key.number)
                        }
                    }
                }

                ZStack {
                    Button {
                        call()
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255), Color(red: 0, green: 155 / 255, blue: 39 / 255)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlaceCall)

                    Button {
                        guard !enteredNumber.isEmpty else { return }
                        enteredNumber.removeLast()
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(enteredNumber.isEmpty ? Color.clear : Color.secondary)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .disabled(enteredNumber.isEmpty)
                    .offset(x: 109)
                }
                .padding(.top, 20)
                .frame(maxWidth: .infinity, minHeight: 80)

                Spacer(minLength: 14)
            }

            if isShowingNewContact {
                NewContactView(
                    initialPhoneNumber: enteredNumber,
                    cancel: { isShowingNewContact = false },
                    save: { contact in
                        onSave(contact)
                        isShowingNewContact = false
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingNewContact)
        .onChange(of: enteredNumber) { _, newValue in
            startLookup(for: newValue)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    // MARK: - The "is this number on HearMeOut?" check

    /// Looks the number up, after a short pause so typing does not fire a
    /// request per keystroke.
    private func startLookup(for number: String) {
        lookupTask?.cancel()
        lookup = .none

        guard isCompleteNumber else { return }

        if PhoneNumber.matchingKey(number) == PhoneNumber.matchingKey(profileStore.phoneNumber) {
            lookup = .ownNumber
            return
        }

        lookup = .checking
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let state = await router.registrationState(for: number)
            guard !Task.isCancelled else { return }

            switch state {
            case .registered:
                lookup = .registered
            case .notOnApp:
                lookup = .notOnApp
            case .unknown, .blocked:
                lookup = .failed
            }

            // Remember the answer on the contact, so the contacts list and
            // the recents can show it without asking again.
            if let contact = contactsStore.contact(matching: number) {
                contactsStore.setRegistration(state, for: contact)
            }
        }
    }

    /// The chip under the number.
    @ViewBuilder
    private var chip: some View {
        switch lookup {
        case .registered:
            chipLabel("On HearMeOut", color: .green)
        case .notOnApp:
            HStack(spacing: 10) {
                chipLabel("Not on HearMeOut", color: .orange)
                Button("Invite") {
                    onInvite(enteredNumber, enteredNumber)
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
            }
        case .ownNumber:
            chipLabel("This is your number", color: .secondary)
        case .failed:
            chipLabel("Check your connection", color: .secondary)
        case .none, .checking:
            Color.clear.frame(height: 1)
        }
    }

    private func chipLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
    }

    // MARK: - Placing the call

    private var canPlaceCall: Bool {
        switch lookup {
        case .ownNumber: return false
        case .none, .checking, .registered, .notOnApp, .failed: return isCompleteNumber
        }
    }

    private func call() {
        switch lookup {
        case .notOnApp:
            // Calling a number that is not on the app would ring nothing.
            // Offer an invite instead.
            onInvite(enteredNumber, enteredNumber)
        case .failed:
            onInvite(enteredNumber, enteredNumber)
        default:
            onCall(enteredNumber)
        }
    }

    private func highlightedPhoneNumber(_ number: String) -> Text {
        guard let range = number.range(of: enteredNumber), !enteredNumber.isEmpty else {
            return Text(number).foregroundColor(.secondary)
        }
        return Text(String(number[..<range.lowerBound])).foregroundColor(.secondary)
            + Text(String(number[range])).foregroundColor(.blue)
            + Text(String(number[range.upperBound...])).foregroundColor(.secondary)
    }
}

/// One round key on the keypad.
private struct KeypadButton: View {
    let number: String
    let letters: String
    /// Held down rather than tapped. The `0` key uses this to enter a
    /// leading `+`, which is how a number with a country code is dialled.
    var longPress: (() -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(number)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.primary)
                Text(letters.isEmpty ? " " : letters)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(.primary)
                    .opacity(letters.isEmpty ? 0 : 1)
            }
            .frame(width: 80, height: 80)
            .background(Color(uiColor: .systemGray5).opacity(0.95), in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.55), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                longPress?()
            }
        )
        .accessibilityLabel(number)
        .accessibilityHint(longPress == nil ? "" : "Hold to enter a plus sign")
    }
}

private extension String {
    /// The keypad digits for a name, so typing "2AZ" can match "Ada".
    var t9Digits: String {
        uppercased().compactMap { character in
            switch character {
            case "A", "B", "C": "2"
            case "D", "E", "F": "3"
            case "G", "H", "I": "4"
            case "J", "K", "L": "5"
            case "M", "N", "O": "6"
            case "P", "Q", "R", "S": "7"
            case "T", "U", "V": "8"
            case "W", "X", "Y", "Z": "9"
            default: nil
            }
        }.joined()
    }
}
