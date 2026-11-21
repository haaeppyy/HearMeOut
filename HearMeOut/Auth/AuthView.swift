import SwiftUI

struct AuthView: View {
    @ObservedObject var auth: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("HearMeOut")
                .font(.largeTitle.bold())
            Text(isCreatingAccount ? "Create an account to receive calls." : "Sign in to make and receive calls.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(isCreatingAccount ? .newPassword : .password)
                .textFieldStyle(.roundedBorder)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(isCreatingAccount ? "Create account" : "Sign in", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || email.isEmpty || password.isEmpty)
            Button(isCreatingAccount ? "I already have an account" : "Create account") {
                message = nil
                isCreatingAccount.toggle()
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(32)
    }

    private func submit() {
        isWorking = true
        message = nil
        Task {
            do {
                if isCreatingAccount {
                    let signedIn = try await auth.signUp(email: email, password: password)
                    if !signedIn {
                        message = "Check your email to confirm the account, then sign in."
                    }
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }
}
