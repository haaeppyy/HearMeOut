import Foundation
import Testing

@testable import HearMeOut

/// E.164 normalization both sides of users-lookup must agree on.
@Suite("Phone normalization")
struct PhoneNormalizationTests {

    @Test("strips formatting, keeps leading +")
    func stripsFormatting() {
        #expect(SupabaseAuthManager.normalizePhone("+1 (555) 000-1234") == "+15550001234")
    }

    @Test("bare 10-digit NANP gains country code 1")
    func nanpDefault() {
        #expect(SupabaseAuthManager.normalizePhone("5550001234") == "+15550001234")
        #expect(SupabaseAuthManager.normalizePhone("+91 98765 43210") == "+919876543210")
    }

    @Test("idempotent on already-clean input")
    func idempotent() {
        let clean = "+15550001111"
        #expect(SupabaseAuthManager.normalizePhone(clean) == clean)
        #expect(SupabaseAuthManager.normalizePhone(SupabaseAuthManager.normalizePhone("(555) 000-1111")) == "+15550001111")
    }
}
