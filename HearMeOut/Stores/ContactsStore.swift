import Foundation
import Combine

/// The user's saved contacts.
///
/// This is the only thing that talks to the contacts table. Views read
/// `contacts` and call the mutating methods; nothing reaches for GRDB
/// directly.
@MainActor
final class ContactsStore: ObservableObject {

    /// The saved contacts, newest write last.
    @Published private(set) var contacts: [Contact] = []

    private let repository: ContactRepository
    private let scope: AccountScope
    private let signaling: CallSignalingClient

    init(repository: ContactRepository, scope: AccountScope, signaling: CallSignalingClient) {
        self.repository = repository
        self.scope = scope
        self.signaling = signaling
    }

    /// Loads the contacts for the current account.
    func load() {
        guard let profileID = scope.profileID else {
            contacts = []
            return
        }
        do {
            contacts = try repository
                .fetchAll(profileID: profileID, includingBlocked: true)
                .map(Contact.init(record:))
        } catch {
            print("Unable to load contacts: \(error)")
        }
    }

    /// Saves a contact, keeping the values that only the stored row knows
    /// about: its id, the cached server link and the registration answer.
    func upsert(_ contact: Contact) {
        guard let profileID = scope.profileID else { return }
        let existing = try? repository.fetch(id: contact.id.uuidString)
        let record = contact.record(
            profileID: profileID,
            existingID: existing?.id ?? contact.id.uuidString,
            existingRemoteUserID: existing?.remoteUserID,
            existingCreatedAt: existing?.createdAt,
            existingCheckedAt: existing?.checkedAt,
            existingRegistrationState: existing?.registration ?? .unknown
        )
        do {
            try repository.upsert(record)
        } catch {
            print("Unable to save contact: \(error)")
            return
        }
        replace(contact)
    }

    /// Removes a contact and the call history rows that pointed at it.
    func delete(_ contact: Contact) {
        do {
            try repository.delete(id: contact.id.uuidString)
        } catch {
            print("Unable to delete contact: \(error)")
            return
        }
        contacts.removeAll { $0.id == contact.id }
    }

    /// Records what the server said about this contact's number.
    func setRegistration(_ state: RegistrationState, for contact: Contact) {
        var revised = contact
        revised.registrationState = state
        revised.checkedAt = Date()
        upsert(revised)
    }

    /// The contact whose number matches the one dialled, if there is one.
    func contact(matching number: String) -> Contact? {
        let key = PhoneNumber.matchingKey(number)
        guard !key.isEmpty else { return nil }
        return contacts.first { $0.normalizedPhone == key }
    }

    /// Every contact whose number matches the one dialled.
    func contacts(matching number: String) -> [Contact] {
        let key = PhoneNumber.matchingKey(number)
        guard !key.isEmpty else { return [] }
        return contacts.filter { $0.normalizedPhone == key }
    }

    /// Block a contact on the server.
    /// - Parameters:
    ///   - contact: The contact to block
    /// - Throws: If the server returns an error
    func block(_ contact: Contact) async throws {
        guard let remoteUserID = contact.remoteUserID else {
            throw ContactsStoreError.missingRemoteUserID
        }
        try await signaling.blockUser(blockedId: remoteUserID)
        // Update local state
        var revised = contact
        revised.isBlocked = true
        upsert(revised)
    }

    /// Unblock a contact on the server.
    /// - Parameters:
    ///   - contact: The contact to unblock
    func unblock(_ contact: Contact) async throws {
        guard let remoteUserID = contact.remoteUserID else {
            throw ContactsStoreError.missingRemoteUserID
        }
        try await signaling.unblockUser(blockedId: remoteUserID)
        // Update local state
        var revised = contact
        revised.isBlocked = false
        upsert(revised)
    }

    /// Check if a contact has been blocked by the current user.
    /// - Parameters:
    ///   - contact: The contact to check
    /// - Returns: true if the contact is blocked
    func isBlocked(_ contact: Contact) async -> Bool {
        guard let remoteUserID = contact.remoteUserID else { return false }
        do {
            return try await signaling.isBlocked(blockedId: remoteUserID)
        } catch {
            print("Unable to check blocked status: \(error)")
            return false
        }
    }

    private func replace(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
            contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

enum ContactsStoreError: Error {
    case missingRemoteUserID
}
