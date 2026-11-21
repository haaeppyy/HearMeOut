import Foundation

/// A person the user has saved in HearMeOut.
///
/// Contacts live on the device only (GRDB). The server is never given the
/// address book — it is only ever asked whether one specific number belongs
/// to a registered user.
struct Contact: Identifiable, Hashable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var isFavorite: Bool
    var details: [String: String] = [:]
    var imageData: Data? = nil
    var isBlocked = false
    /// The server's user id for this contact, once a lookup has found one.
    /// Cached so redialing does not need another round trip.
    var remoteUserID: String?
    /// Whether the server knows this contact's number.
    var registrationState: RegistrationState = .unknown
    /// When `registrationState` was last refreshed from the server.
    var checkedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        phoneNumber: String,
        isFavorite: Bool,
        details: [String: String] = [:],
        imageData: Data? = nil,
        isBlocked: Bool = false,
        remoteUserID: String? = nil,
        registrationState: RegistrationState = .unknown,
        checkedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.isFavorite = isFavorite
        self.details = details
        self.imageData = imageData
        self.isBlocked = isBlocked
        self.remoteUserID = remoteUserID
        self.registrationState = registrationState
        self.checkedAt = checkedAt
    }

    /// The key used to match a dialed number against this contact.
    ///
    /// Digits only, with the default country code applied to a bare 10-digit
    /// number, so `9876543210` and `+91 98765 43210` are the same contact.
    var normalizedPhone: String {
        PhoneNumber.matchingKey(phoneNumber)
    }
}
