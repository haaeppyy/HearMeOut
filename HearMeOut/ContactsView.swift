import SwiftUI
import UIKit
import PhotosUI

struct Contact: Identifiable, Hashable {
    let id: UUID
    let name: String
    let phoneNumber: String
    var isFavorite: Bool
    var details: [String: String] = [:]
    var imageData: Data? = nil
    var isBlocked = false
    /// Supabase user id resolved via users-lookup. Nil = not on Hear Me Out
    /// yet (or backend not configured) — calls to this contact are blocked
    /// with an explanation instead of attempted.
    var remoteUserID: String? = nil

    init(id: UUID = UUID(), name: String, phoneNumber: String, isFavorite: Bool, details: [String: String] = [:], imageData: Data? = nil, isBlocked: Bool = false, remoteUserID: String? = nil) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.isFavorite = isFavorite
        self.details = details
        self.imageData = imageData
        self.isBlocked = isBlocked
        self.remoteUserID = remoteUserID
    }

    /// Displayed next to contacts that can't receive backend calls.
    var isCallable: Bool { remoteUserID?.isEmpty == false }
}

struct ContactsView: View {
    let profileImage: UIImage?
    @Binding var contacts: [Contact]
    let startAudioCall: (Contact) -> Void
    /// Passthrough to NewContactView/ContactDetailView (no observation here).
    var coordinator: CallCoordinator? = nil
    @State private var isShowingNewContact = false
    @State private var selectedContact: Contact?
    @State private var isShowingMyProfile = false

    private var favorites: [Contact] {
        contacts.filter { $0.isFavorite && !$0.isBlocked }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoriteRows: [ContactListItem] {
        favorites.map { ContactListItem(contact: $0, id: "favourite-\($0.id.uuidString)") }
    }

    private var contactSections: [ContactSection] {
        // Favourites remain in this source collection so they also appear in
        // their normal alphabetic section below the separate favourites list.
        Dictionary(grouping: contacts.filter { !$0.isBlocked }, by: sectionTitle)
            .map { letter, contacts in
                ContactSection(
                    letter: letter,
                    contacts: contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { lhs, rhs in
                // Keep non-alphabetic names together at the very end, after Z.
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter.localizedCaseInsensitiveCompare(rhs.letter) == .orderedAscending
            }
    }

    private func sectionTitle(for contact: Contact) -> String {
        let trimmedName = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedName.first,
              firstCharacter.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return "#"
        }
        return String(firstCharacter).uppercased()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            ZStack {
                Text("Contacts")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)

                HStack {
                    Spacer()
                    Button { isShowingNewContact = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.black)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add contact")
                }
            }
            .padding(.trailing, 18)
            .padding(.leading, 18)
            .frame(height: 46)
            .padding(.top, 8)

                ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 13) {
                    Text("All contacts")
                        .font(.system(size: 16))
                        .foregroundStyle(.black)
                        .padding(.top, 24)
                        .frame(width: 343, alignment: .leading)
                        .frame(maxWidth: .infinity)

                    ProfileContactCard(image: profileImage) {
                        isShowingMyProfile = true
                    }

                    if !favorites.isEmpty {
                        Text("Favourites")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                            .frame(width: 343, alignment: .leading)
                            .frame(maxWidth: .infinity)

                        ForEach(favoriteRows) { item in
                            ContactRow(contact: item.contact, showFavoriteIcon: true) {
                                selectedContact = item.contact
                            }
                        }
                    }

                    ForEach(contactSections) { section in
                        Text(section.letter)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, favorites.isEmpty ? 16 : 8)
                            .frame(width: 343, alignment: .leading)
                            .frame(maxWidth: .infinity)

                        ForEach(section.contacts.map { contact in
                            ContactListItem(contact: contact, id: "directory-\(section.letter)-\(contact.id.uuidString)")
                        }) { item in
                            ContactRow(contact: item.contact) {
                                selectedContact = item.contact
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                }
            }

            if isShowingNewContact {
                NewContactView(
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
        .animation(.easeInOut(duration: 0.22), value: isShowingNewContact)
        .fullScreenCover(item: $selectedContact) { contact in
            ContactDetailView(
                contact: contact,
                close: { selectedContact = nil },
                update: { updated in
                    guard let index = contacts.firstIndex(where: { $0.id == updated.id }) else { return }
                    contacts[index] = updated
                    selectedContact = updated
                },
                delete: { contactToDelete in
                    contacts.removeAll { $0.id == contactToDelete.id }
                    selectedContact = nil
                },
                startAudioCall: { contactToCall in
                    selectedContact = nil
                    DispatchQueue.main.async {
                        startAudioCall(contactToCall)
                    }
                },
                coordinator: coordinator
            )
        }
        .fullScreenCover(isPresented: $isShowingMyProfile) {
            MyProfileContactDetailView(image: profileImage) {
                isShowingMyProfile = false
            }
        }
    }
}

private struct ProfileContactCard: View {
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ProfileAvatar(size: 38, image: image)
                Text("My profile")
                    .font(.system(size: 16))
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(width: 343, height: 62)
            .background(Color(uiColor: .systemGray5).opacity(0.78), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct MyProfileContactDetailView: View {
    let image: UIImage?
    let close: () -> Void
    @AppStorage("userName") private var userName = ""
    @AppStorage("userPhoneNumber") private var userPhoneNumber = ""
    @AppStorage("communicationProfile") private var communicationProfile = ""

    private var communicationDescription: String? {
        switch communicationProfile {
        case "hearAndSpeak": "I can hear & speak"
        case "hearOnly": "I can hear, but I can’t speak"
        case "partialHearing": "I have partial hearing"
        case "speakOnly": "I can speak, but I can’t hear"
        case "textOnly": "I can’t hear or speak"
        default: nil
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ProfileAvatar(size: 194, image: image)
                        .padding(.top, 86)
                    Text(userName)
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.top, 32)

                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        profileDetail(label: "Phone", value: userPhoneNumber)

                        if let communicationDescription {
                            Divider()
                            profileDetail(label: "Communication", value: communicationDescription)
                        }
                        Divider()
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 40)
                    .padding(.bottom, 36)
                }
            }

            CircleActionButton(symbol: "chevron.left", action: close)
                .padding(.leading, 28)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func profileDetail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium))
        }
        .padding(.vertical, 19)
    }
}

private struct ContactRow: View {
    let contact: Contact
    var showFavoriteIcon = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
            ContactAvatar(contact: contact, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 16))
                    .foregroundStyle(.black)
                // Phase 8 linkage state: a contact that can't be called
                // reads as "not on Hear Me Out yet" instead of failing
                // silently when dialed.
                if AppConfig.isBackendConfigured {
                    Text(contact.isCallable ? "On Hear Me Out" : "Not on Hear Me Out yet")
                        .font(.system(size: 12))
                        .foregroundStyle(contact.isCallable ? Color.green : Color.secondary)
                }
            }

            Spacer()

            if showFavoriteIcon {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.favoriteGradient)
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 343, height: 62)
        .background(Color(uiColor: .systemGray5).opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private static let favoriteGradient = LinearGradient(
        colors: [
            .red,
            Color(red: 0.78, green: 0, blue: 0.08)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private struct ContactSection: Identifiable {
    let letter: String
    let contacts: [Contact]
    var id: String { letter }
}

private struct ContactListItem: Identifiable {
    let contact: Contact
    let id: String
}

struct ContactAvatar: View {
    let contact: Contact
    let size: CGFloat

    private var initials: String {
        contact.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Group {
            if let data = contact.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(ProfileAvatar.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct ContactDetailView: View {
    let contact: Contact
    let close: () -> Void
    let update: (Contact) -> Void
    let delete: (Contact) -> Void
    let startAudioCall: (Contact) -> Void
    var coordinator: CallCoordinator? = nil
    @State private var isEditing = false

    private var additionalDetailRows: [(label: String, value: String)] {
        contact.details
            .filter {
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !["First name", "Last name", "Company"].contains($0.key) &&
                $0.value != contact.phoneNumber
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    ContactAvatar(contact: contact, size: 194)
                        .padding(.top, 86)
                    Text(contact.name)
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.top, 32)
                    if AppConfig.isBackendConfigured {
                        Text(contact.isCallable ? "On Hear Me Out — callable" : "Not on Hear Me Out yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(contact.isCallable ? Color.green : Color.secondary)
                            .padding(.top, 8)
                    }

                    HStack(spacing: 40) {
                        ContactQuickAction(symbol: "square.and.arrow.up", title: "Share") { }
                        ContactQuickAction(symbol: contact.isFavorite ? "heart.fill" : "heart", title: "Favourite") {
                            var revised = contact
                            revised.isFavorite.toggle()
                            update(revised)
                        }
                        ContactQuickAction(symbol: "phone", title: "Call") { startAudioCall(contact) }
                        ContactQuickAction(symbol: "recordingtape", title: "Voicemail") { }
                    }
                    .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        Text("Phone")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                        Text(contact.phoneNumber)
                            .font(.system(size: 20, weight: .medium))
                            .padding(.top, 8)
                            .padding(.bottom, 24)

                        if !additionalDetailRows.isEmpty {
                            Divider()
                            ForEach(additionalDetailRows, id: \.label) { row in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(row.label)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(row.value)
                                        .font(.system(size: 20, weight: .medium))
                                }
                                .padding(.vertical, 19)
                            }
                        }
                        Divider()
                        Text("Call History")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                        ContactCallHistory()
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 40)
                    .padding(.bottom, 36)
                }
            }
            ZStack {
                CircleActionButton(symbol: "chevron.left", action: close)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") { isEditing = true }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 25)
                    .frame(height: 46)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.9), lineWidth: 0.8) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if isEditing {
                NewContactView(
                    contactToEdit: contact,
                    cancel: { isEditing = false },
                    save: { update($0); isEditing = false },
                    deleteContact: { delete(contact) },
                    blockContact: {
                        var revised = contact
                        revised.isBlocked = true
                        update(revised)
                        isEditing = false
                    },
                    coordinator: coordinator
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isEditing)
    }
}

private struct ContactQuickAction: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .systemGray5).opacity(0.85), in: Circle())
                Text(title).font(.system(size: 14)).foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ContactCallHistory: View {
    private let entries = [("Outgoing ↗ · 5 mins", "arrow.up.right"), ("Incoming ↙ · 5 mins", "arrow.down.left"), ("Didn't connect", "phone.down")]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Sept 1, 2026").font(.system(size: 18, weight: .medium))
                        Text(entry.0).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("11:27 AM").font(.system(size: 17, weight: .medium))
                }
                .padding(.vertical, 12)
                if index < entries.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 26)
        .background(Color(uiColor: .systemGray5).opacity(0.86), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(width: 353, height: 234)
    }
}

struct NewContactView: View {
    let contactToEdit: Contact?
    let cancel: () -> Void
    let save: (Contact) -> Void
    let deleteContact: (() -> Void)?
    let blockContact: (() -> Void)?
    /// Passthrough for resolve-on-save (method calls only, no observation).
    var coordinator: CallCoordinator?
    @State private var isLinking = false

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var company = ""
    @State private var phoneNumber = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var contactPhoto: UIImage?
    @State private var isShowingFieldPicker = false
    @State private var phoneLabel = "Mobile"
    @State private var isShowingPhoneLabelPicker = false
    @State private var isShowingCustomLabelPrompt = false
    @State private var customPhoneLabel = ""
    @State private var additionalFields: [String] = []
    @State private var additionalValues: [String: String] = [:]

    private let availableFieldTypes = ["Address", "Pronouns", "Nickname", "Birthday", "Relationship", "Email", "Notes", "Instant message", "Social Profile", "URL"]

    init(
        contactToEdit: Contact? = nil,
        initialPhoneNumber: String = "",
        cancel: @escaping () -> Void,
        save: @escaping (Contact) -> Void,
        deleteContact: (() -> Void)? = nil,
        blockContact: (() -> Void)? = nil,
        coordinator: CallCoordinator? = nil
    ) {
        self.contactToEdit = contactToEdit
        self.cancel = cancel
        self.save = save
        self.deleteContact = deleteContact
        self.blockContact = blockContact
        self.coordinator = coordinator

        let details = contactToEdit?.details ?? [:]
        let nameParts = (contactToEdit?.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        _firstName = State(initialValue: details["First name"] ?? nameParts.first ?? "")
        _lastName = State(initialValue: details["Last name"] ?? (nameParts.count > 1 ? nameParts[1] : ""))
        _company = State(initialValue: details["Company"] ?? "")
        _phoneNumber = State(initialValue: contactToEdit?.phoneNumber ?? initialPhoneNumber)
        _contactPhoto = State(initialValue: contactToEdit?.imageData.flatMap { UIImage(data: $0) })

        let standardKeys = Set(["First name", "Last name", "Company", "Blocked"])
        let phoneValue = contactToEdit?.phoneNumber ?? ""
        let extras = details
            .filter { !standardKeys.contains($0.key) && $0.value != phoneValue }
            .map(\.key)
            .sorted()
        _additionalFields = State(initialValue: extras)
        _additionalValues = State(initialValue: Dictionary(uniqueKeysWithValues: extras.map { ($0, details[$0, default: ""]) }))
        if let phoneKey = details.first(where: { $0.value == phoneValue && !standardKeys.contains($0.key) })?.key {
            _phoneLabel = State(initialValue: phoneKey)
        }
    }

    private var remainingFieldTypes: [String] {
        availableFieldTypes.filter { !additionalFields.contains($0) }
    }

    private var fullName: String {
        [firstName, lastName]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    private var contactDetails: [String: String] {
        var details = [
            "First name": firstName,
            "Last name": lastName,
            "Company": company,
            phoneLabel: phoneNumber
        ]
        additionalFields.forEach { details[$0] = additionalValues[$0, default: ""] }
        return details
    }

    /// Build the contact, then resolve its phone to a remoteUserID before
    /// saving so every saved contact carries its linkage state. Unresolvable
    /// numbers still save — they read as "not on Hear Me Out yet".
    private func saveLinkedContact() {
        let name = fullName.isEmpty ? "Unnamed Contact" : fullName
        let base: Contact
        if let updated = contactToEdit {
            base = Contact(
                id: updated.id,
                name: name,
                phoneNumber: phoneNumber,
                isFavorite: updated.isFavorite,
                details: contactDetails,
                imageData: contactPhoto?.jpegData(compressionQuality: 0.9),
                isBlocked: updated.isBlocked,
                remoteUserID: updated.remoteUserID
            )
        } else {
            base = Contact(name: name, phoneNumber: phoneNumber, isFavorite: false, details: contactDetails, imageData: contactPhoto?.jpegData(compressionQuality: 0.9))
        }
        guard let coordinator else {
            save(base)
            return
        }
        isLinking = true
        Task {
            var linked = base
            if let hit = await coordinator.resolveContact(phone: base.phoneNumber) {
                linked.remoteUserID = hit.id
            }
            isLinking = false
            save(linked)
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ZStack {
                        Text(contactToEdit == nil ? "New Contact" : "Edit Contact")
                            .font(.system(size: 24, weight: .bold))

                        HStack {
                            CircleActionButton(symbol: "chevron.left", action: cancel)
                            Spacer()
                            CircleActionButton(symbol: "checkmark") {
                                saveLinkedContact()
                            }
                            .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLinking)
                            .accessibilityLabel("Save contact")
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 18)

                    VStack(spacing: 20) {
                        ProfileAvatar(size: 80, image: contactPhoto)

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Text("Add Photo")
                                .font(.system(size: 16))
                                .foregroundStyle(.black)
                                .frame(width: 126, height: 50)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 1000, style: .continuous))
                                .overlay { RoundedRectangle(cornerRadius: 1000, style: .continuous).stroke(.white.opacity(0.9), lineWidth: 0.8) }
                        }
                    }
                    .padding(.top, 22)
                    .onChange(of: selectedPhoto) { _, newPhoto in
                        Task {
                            guard let newPhoto,
                                  let data = try? await newPhoto.loadTransferable(type: Data.self),
                                  let image = UIImage(data: data) else { return }
                            await MainActor.run { contactPhoto = image }
                        }
                    }

                    VStack(spacing: 0) {
                        ContactTextField(title: "First name", text: $firstName)
                        ContactTextField(title: "Last name", text: $lastName)
                        ContactTextField(title: "Company", text: $company, showsSeparator: false)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 3)
                    .background(Color(uiColor: .systemGray5).opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 40)
                    .padding(.top, 28)

                    HStack(spacing: 14) {
                        Button { isShowingPhoneLabelPicker = true } label: {
                            HStack(spacing: 7) {
                                Text(phoneLabel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Divider().frame(height: 32)
                        TextField("Phone", text: $phoneNumber)
                            .keyboardType(.phonePad)
                            .font(.system(size: 16))
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 22)
                    .frame(height: 54)
                    .background(Color(uiColor: .systemGray5).opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 40)
                    .padding(.top, 20)

                    HStack {
                        Text("Ringtone")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Default")
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 22)
                    .frame(height: 54)
                    .background(Color(uiColor: .systemGray5).opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 40)
                    .padding(.top, 20)

                    ForEach(additionalFields, id: \.self) { field in
                        AdditionalContactField(
                            title: field,
                            value: Binding(
                                get: { additionalValues[field, default: ""] },
                                set: { additionalValues[field] = $0 }
                            )
                        )
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                    }

                    Button { isShowingFieldPicker = true } label: {
                        Text("Add another field")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .frame(height: 54)
                            .background(Color(uiColor: .systemGray5).opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, contactToEdit == nil ? 40 : 120)
                }
            }

            if let deleteContact, let blockContact {
                HStack(spacing: 16) {
                    EditorDangerAction(symbol: "trash", title: "Delete", action: deleteContact)
                    EditorDangerAction(symbol: "x.circle", title: "Block", action: blockContact)
                }
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .sheet(isPresented: $isShowingFieldPicker) {
            AdditionalFieldsSheet(availableFields: remainingFieldTypes) { field in
                additionalFields.append(field)
                isShowingFieldPicker = false
            }
                .presentationDetents([.fraction(0.62)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(38)
        }
        .confirmationDialog("Phone label", isPresented: $isShowingPhoneLabelPicker, titleVisibility: .hidden) {
            ForEach(["Mobile", "Home", "Work", "Custom"], id: \.self) { label in
                Button(label) {
                    if label == "Custom" {
                        customPhoneLabel = ""
                        isShowingCustomLabelPrompt = true
                    } else {
                        phoneLabel = label
                    }
                }
            }
        }
        .alert("Custom phone label", isPresented: $isShowingCustomLabelPrompt) {
            TextField("Label", text: $customPhoneLabel)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                let label = customPhoneLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    phoneLabel = label
                }
            }
        } message: {
            Text("Enter a label for this phone number.")
        }
    }
}

private struct EditorDangerAction: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(Color.red)
            .frame(width: 132, height: 52)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.9), lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct CircleActionButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "checkmark" ? 27 : 25, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
    }
}

private struct ContactTextField: View {
    let title: String
    @Binding var text: String
    var showsSeparator = true

    var body: some View {
        TextField(title, text: $text)
            .font(.system(size: 16))
            .frame(height: 54)
            .overlay(alignment: .bottom) {
                if showsSeparator {
                    Divider().padding(.horizontal, 5)
                }
            }
    }
}

private struct AdditionalContactField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        Group {
            if title == "Birthday" {
                HStack(spacing: 14) {
                    Text("Birthday")
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 32)
                    TextField("Birthday", text: $value)
                }
                .padding(.horizontal, 22)
            } else {
                TextField(title, text: $value)
                    .padding(.horizontal, 22)
            }
        }
        .font(.system(size: 16))
        .frame(height: 54)
        .background(Color(uiColor: .systemGray5).opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AdditionalFieldsSheet: View {
    let availableFields: [String]
    let addField: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Add another field")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 42)
                .padding(.bottom, 16)

            ForEach(availableFields, id: \.self) { field in
                Button { addField(field) } label: {
                    HStack(spacing: 22) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 31, height: 31)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255), Color(red: 0, green: 155 / 255, blue: 39 / 255)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )

                    Text(field)
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 36)
                .frame(height: 45)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
