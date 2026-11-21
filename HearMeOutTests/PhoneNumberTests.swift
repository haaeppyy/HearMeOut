import Testing
@testable import HearMeOut

/// The single canonical representation used for a phone number anywhere in
/// HearMeOut. Both the profile the user saves and the number the app looks
/// up have to go through this, or a contact saved as `9876543210` would never
/// match a stored `+919876543210`.
@Suite("Phone number normalisation")
struct PhoneNumberTests {

    @Test("A bare 10-digit number gains the +91 country code")
    func tenDigitNumberGetsDefaultCountryCode() throws {
        #expect(try PhoneNumber.normalize("9876543210") == "+919876543210")
    }

    @Test("Spacing and punctuation are ignored")
    func formattingIsStripped() throws {
        #expect(try PhoneNumber.normalize("+91 98765 43210") == "+919876543210")
        #expect(try PhoneNumber.normalize("98765 43210") == "+919876543210")
        #expect(try PhoneNumber.normalize("(98765) 43210") == "+919876543210")
    }

    @Test("An international number is kept as entered")
    func internationalNumberIsPreserved() throws {
        #expect(try PhoneNumber.normalize("+14155552671") == "+14155552671")
    }

    @Test("A number that is too short or too long is rejected")
    func invalidLengthIsRejected() {
        #expect(throws: PhoneNumber.ValidationError.self) {
            try PhoneNumber.normalize("98765")
        }
        #expect(throws: PhoneNumber.ValidationError.self) {
            try PhoneNumber.normalize("+1234567890123456")
        }
    }

    @Test("A number starting with 0 after the country code is rejected")
    func leadingZeroIsRejected() {
        #expect(throws: PhoneNumber.ValidationError.self) {
            try PhoneNumber.normalize("+0919876543210")
        }
    }
}
