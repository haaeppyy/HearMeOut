import Testing
@testable import HearMeOut

/// The root state machine decides what the user sees: the sign-in screen,
/// onboarding, or the app itself.
@Suite("Root state machine")
struct RootStateTests {

    @Test("A session that is still being restored hides everything else")
    func restoringSessionWins() {
        #expect(RootState.resolve(
            isRestoringSession: true,
            isSignedIn: false,
            isProfileLoaded: false,
            needsOnboarding: true
        ) == .restoringSession)
    }

    @Test("Without a session the user is asked to sign in")
    func signedOutWhenThereIsNoSession() {
        #expect(RootState.resolve(
            isRestoringSession: false,
            isSignedIn: false,
            isProfileLoaded: true,
            needsOnboarding: false
        ) == .signedOut)
    }

    @Test("A signed-in account waits for its profile before anything else")
    func waitsForTheProfile() {
        #expect(RootState.resolve(
            isRestoringSession: false,
            isSignedIn: true,
            isProfileLoaded: false,
            needsOnboarding: false
        ) == .loadingProfile)
    }

    @Test("An account without a communication profile goes through onboarding")
    func needsOnboardingWhenTheProfileIsEmpty() {
        #expect(RootState.resolve(
            isRestoringSession: false,
            isSignedIn: true,
            isProfileLoaded: true,
            needsOnboarding: true
        ) == .needsOnboarding)
    }

    @Test("A set-up account goes straight to the app")
    func mainWhenEverythingIsInPlace() {
        #expect(RootState.resolve(
            isRestoringSession: false,
            isSignedIn: true,
            isProfileLoaded: true,
            needsOnboarding: false
        ) == .main)
    }
}

/// The communication profile drives the default calling interface.
@Suite("Communication profile")
struct CommunicationProfileTests {

    @Test("Only the hearing-and-speaking profile defaults to audio")
    func audioOnlyForHearingAndSpeaking() {
        #expect(CommunicationProfile.hearAndSpeak.defaultCallingInterface == "Audio Mode")
        for profile in CommunicationProfile.allCases where profile != .hearAndSpeak {
            #expect(profile.defaultCallingInterface == "Text Mode")
        }
    }

    @Test("Every profile has a title, a description and a symbol")
    func everyProfileIsDescribed() {
        for profile in CommunicationProfile.allCases {
            #expect(!profile.title.isEmpty)
            #expect(!profile.description.isEmpty)
            #expect(!profile.symbol.isEmpty)
        }
    }
}
