import Foundation

/// The single canonical representation used by both profile saving and
/// contact lookup. Keeping it here prevents a number from being stored in
/// one format and searched for in another.
enum PhoneNumber {
    static let defaultCountryCode = "+91"

    enum ValidationError: LocalizedError {
        case invalid

        var errorDescription: String? {
            "Enter a 10-digit Indian number, or a full international number beginning with +."
        }
    }

    /// The E.164 form of a number, as the server stores and compares it.
    ///
    /// Throws rather than guessing: a number the server will not recognise
    /// should fail loudly at the point the user typed it, not turn into a
    /// call that never rings.
    static func normalize(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)

        if trimmed.hasPrefix("+") {
            guard (8...15).contains(digits.count), digits.first != "0" else {
                throw ValidationError.invalid
            }
            return "+" + digits
        }

        guard digits.count == 10 else { throw ValidationError.invalid }
        return defaultCountryCode + digits
    }

    /// A digits-only key for matching a typed number against a saved one.
    ///
    /// Unlike `normalize`, this never throws: it is used to look a contact
    /// up while the user is still typing, and a number that is not a valid
    /// phone number still has to match something (or nothing) without
    /// interrupting the keystroke.
    ///
    /// A bare 10-digit number gains the default country code, so a contact
    /// saved as `9876543210` matches one dialled as `+919876543210`.
    static func matchingKey(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        if digits.count == 10 {
            return defaultCountryCode.filter(\.isNumber) + digits
        }
        return digits
    }
}
