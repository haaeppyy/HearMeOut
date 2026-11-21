import SwiftUI
import UIKit
import PhotosUI

/// The Contacts tab: favourites, the alphabetical directory, and the
/// new-contact / my-profile entry points.
struct ContactsView: View {
    let profileImage: UIImage?
    let contacts: [Contact]
    /// Saves a new or edited contact.
    let onSave: (Contact) -> Void
    /// Removes a contact.
    let onDelete: (Contact) -> Void
    /// Starts a call to a contact.
    let onCall: (Contact) -> Void
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
                        onSave(contact)
                        isShowingNewContact = false
                    }
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
                    onSave(updated)
                    selectedContact = updated
                },
                delete: { contactToDelete in
                    onDelete(contactToDelete)
                    selectedContact = nil
                },
                startAudioCall: { contactToCall in
                    selectedContact = nil
                    DispatchQueue.main.async {
                        onCall(contactToCall)
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingMyProfile) {
            MyProfileContactDetailView(image: profileImage) {
                isShowingMyProfile = false
            }
        }
    }
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
