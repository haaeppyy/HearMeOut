import SwiftUI

/// The active call screen.
///
/// It shows one of two skins over the same view model — the audio skin and
/// the text skin — and the user can swap between them while the call is
/// running without interrupting it. Which skin opens first is the user's
/// default calling interface.
///
/// The container owns the view model for the length of the call; the skins
/// only observe it.
struct ActiveCallContainer: View {
    @StateObject private var viewModel: CallViewModel
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var contactsStore: ContactsStore

    /// Which skin is showing. `nil` until the default has been applied.
    @State private var skin: Skin?

    private enum Skin {
        case audio
        case text
    }

    init(viewModel: CallViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            switch skin {
            case .audio:
                AudioCallView(
                    viewModel: viewModel,
                    contact: contact,
                    showTextMode: { skin = .text },
                    endCall: { viewModel.endCall() }
                )
            case .text:
                TextCallView(
                    viewModel: viewModel,
                    contact: contact,
                    showAudioMode: { skin = .audio },
                    endCall: { viewModel.endCall() }
                )
            case nil:
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            guard skin == nil else { return }
            skin = profileStore.defaultCallingInterface == "Text Mode" ? .text : .audio
            // Captions and speech synthesis follow the user's language.
            viewModel.setLanguage(profileStore.language)
        }
        .onChange(of: skin) { _, newSkin in
            viewModel.callMode = newSkin == .text ? "text" : "audio"
        }
    }

    /// The saved contact for the other party, when the app knows them.
    private var contact: Contact? {
        guard let phone = viewModel.otherPartyPhone else { return nil }
        return contactsStore.contact(matching: phone)
    }
}
