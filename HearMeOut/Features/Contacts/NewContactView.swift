import SwiftUI
import UIKit
import PhotosUI

/// The new-contact / edit-contact editor.
struct NewContactView: View {
    let contactToEdit: Contact?
    let cancel: () -> Void
    let save: (Contact) -> Void
    let deleteContact: (() -> Void)?
    let blockContact: (() -> Void)?

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
        blockContact: (() -> Void)? = nil
    ) {
        self.contactToEdit = contactToEdit
        self.cancel = cancel
        self.save = save
        self.deleteContact = deleteContact
        self.blockContact = blockContact

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
                                let name = fullName.isEmpty ? "Unnamed Contact" : fullName
                                if var updated = contactToEdit {
                                    updated = Contact(
                                        id: updated.id,
                                        name: name,
                                        phoneNumber: phoneNumber,
                                        isFavorite: updated.isFavorite,
                                        details: contactDetails,
                                        imageData: contactPhoto?.jpegData(compressionQuality: 0.9),
                                        isBlocked: updated.isBlocked
                                    )
                                    save(updated)
                                } else {
                                    save(Contact(name: name, phoneNumber: phoneNumber, isFavorite: false, details: contactDetails, imageData: contactPhoto?.jpegData(compressionQuality: 0.9)))
                                }
                            }
                            .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

/// Red destructive action button shown at the bottom of the contact editor.
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

/// A labelled text field inside the grouped editor card.
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

/// One of the optional extra fields (Address, Birthday, …).
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

/// The sheet that lets the user add another optional field.
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
