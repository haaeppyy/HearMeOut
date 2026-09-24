import SwiftUI

struct KeypadView: View {
    @Binding var contacts: [Contact]
    let startAudioCall: (String) -> Void
    /// Passthrough only (no published reads need observation here).
    var coordinator: CallCoordinator? = nil
    @State private var enteredNumber = ""
    @State private var isShowingNewContact = false
    /// Last typed number confirmed resolvable to a registered user.
    @State private var reachableNumber: String?
    @State private var isResolving = false

    /// Backend keypad policy (Gap #3 decision): free-dial is disabled — the
    /// call button enables only for numbers that resolve to a registered
    /// user. Local-only mode keeps the old free-dial behavior.
    private var isBackendDialing: Bool {
        coordinator?.auth.isAuthenticated == true && AppConfig.isBackendConfigured
    }

    private var canCall: Bool {
        guard !enteredNumber.isEmpty else { return false }
        guard isBackendDialing else { return true }
        return reachableNumber == enteredNumber
    }

    private let keys: [(number: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]

    private var matchingContacts: [Contact] {
        guard !enteredNumber.isEmpty else { return [] }
        return contacts.filter { contact in
            guard !contact.isBlocked else { return false }
            return contact.phoneNumber.filter(\.isNumber).contains(enteredNumber) ||
                contact.name.t9Digits.contains(enteredNumber)
        }
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
                    .padding(.bottom, 4)

                if isBackendDialing, !enteredNumber.isEmpty {
                    Text(isResolving ? "Looking up…" : (reachableNumber == enteredNumber ? "On Hear Me Out" : "Not on Hear Me Out yet"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(reachableNumber == enteredNumber ? Color.green : Color.secondary)
                        .frame(height: 18)
                        .padding(.bottom, 12)
                } else {
                    Color.clear.frame(height: 0).padding(.bottom, 16)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(80), spacing: 20), count: 3),
                    spacing: 20
                ) {
                    ForEach(keys, id: \.number) { key in
                        KeypadButton(number: key.number, letters: key.letters) {
                            enteredNumber.append(key.number)
                        }
                    }
                }

                ZStack {
                    Button {
                        guard !enteredNumber.isEmpty else { return }
                        startAudioCall(enteredNumber)
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
                    .disabled(!canCall)
                    .opacity(canCall ? 1 : 0.45)
                    .accessibilityLabel("Call")

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
                        contacts.append(contact)
                        isShowingNewContact = false
                    },
                    coordinator: coordinator
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingNewContact)
        .task(id: enteredNumber) {
            await resolveEnteredNumber(enteredNumber)
        }
    }

    /// Debounced users-lookup for the typed number. Stale results are
    /// discarded: only the latest task may write reachableNumber.
    private func resolveEnteredNumber(_ number: String) async {
        guard isBackendDialing, !number.isEmpty else {
            reachableNumber = nil
            isResolving = false
            return
        }
        isResolving = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        let hit = await coordinator?.resolveContact(phone: number)
        guard !Task.isCancelled else { return }
        reachableNumber = hit == nil ? nil : number
        isResolving = false
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

private struct KeypadButton: View {
    let number: String
    let letters: String
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
        .accessibilityLabel(number)
    }
}

private struct SaveNumberSheet: View {
    let number: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("Save Contact")
                .font(.system(size: 20, weight: .semibold))
            Text(number)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            TextField("Contact name", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Save") { save(name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 16, weight: .semibold))
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private extension String {
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
