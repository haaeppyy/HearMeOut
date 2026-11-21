import Foundation
import Combine

/// Decides what happens when the user places a call.
///
/// Every entry point — the keypad, a contact row, a recents row, a search
/// result, the redial button — goes through here, so the rules about
/// looking a number up and about refusing to call someone who is not on
/// HearMeOut yet live in one place rather than being repeated in each
/// screen.
@MainActor
final class CallRouter: ObservableObject {

    /// What happened when the user asked for a call.
    enum Outcome {
        /// The call is under way.
        case started
        /// The number is not registered. The user gets an invite instead of
        /// a call that would never ring.
        case notOnHearMeOut(displayName: String)
        /// Something went wrong.
        case failed(String)
    }

    private let signaling: CallSignalingClient
    private let contactsStore: ContactsStore
    private let coordinator: AppCallCoordinator

    init(signaling: CallSignalingClient, contactsStore: ContactsStore, coordinator: AppCallCoordinator) {
        self.signaling = signaling
        self.contactsStore = contactsStore
        self.coordinator = coordinator
    }

    /// Places a call to a number, or to a saved contact.
    func place(number: String, contact: Contact?) async -> Outcome {
        // Normalise first: the server compares E.164 verbatim, so the number
        // has to be in that form before it goes anywhere.
        let normalized: String
        do {
            normalized = try PhoneNumber.normalize(number)
        } catch {
            return .failed("That doesn't look like a phone number.")
        }

        // Resolve who is on the other end. A contact the app has called
        // before already knows its user id, so the lookup is skipped.
        let resolved: (id: String, displayName: String)
        do {
            if let contact, let remoteUserID = contact.remoteUserID {
                resolved = (remoteUserID, contact.name)
            } else {
                let match = try await signaling.lookupUser(phone: normalized)
                resolved = (match.id, match.displayName ?? contact?.name ?? normalized)
                if var contact {
                    // Cache the link so the next call to this contact does
                    // not need another round trip.
                    contact.remoteUserID = match.id
                    contactsStore.upsert(contact)
                }
            }
        } catch {
            if Self.isNotFound(error) {
                return .notOnHearMeOut(displayName: contact?.name ?? normalized)
            }
            return .failed(Self.message(for: error))
        }

        coordinator.startOutgoingCall(
            target: .contact(id: resolved.id, displayName: resolved.displayName),
            phone: contact?.phoneNumber ?? normalized,
            remoteUserID: resolved.id
        )
        return .started
    }

    /// Asks the server whether a number belongs to someone on HearMeOut.
    ///
    /// This is the "is this number on HearMeOut?" check behind the keypad
    /// chip. It is best-effort: a failure is reported as "unknown" rather
    /// than as a wrong answer.
    func registrationState(for number: String) async -> RegistrationState {
        guard let normalized = try? PhoneNumber.normalize(number) else { return .unknown }
        do {
            _ = try await signaling.lookupUser(phone: normalized)
            return .registered
        } catch {
            return Self.isNotFound(error) ? .notOnApp : .unknown
        }
    }

    /// Whether the server said the number is not registered.
    static func isNotFound(_ error: Error) -> Bool {
        guard let error = error as? CallSignalingClient.SignalingError,
              case .serverError(let status, _) = error else { return false }
        return status == 404
    }

    /// A message worth showing the user.
    static func message(for error: Error) -> String {
        if let error = error as? CallSignalingClient.SignalingError,
           case .serverError(let status, let message) = error {
            switch status {
            case 400: return "That phone number or user ID is not valid."
            case 404: return "No HearMeOut account was found for that phone number."
            case 429: return "Too many attempts. Please wait a moment and try again."
            default: break
            }
            if let message { return message }
        }
        return error.localizedDescription
    }
}
