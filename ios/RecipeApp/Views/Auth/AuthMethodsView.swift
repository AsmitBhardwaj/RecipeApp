//
//  AuthMethodsView.swift
//  RecipeApp
//
//  The shared sign-in method stack — Sign in with Apple (native), Google, and
//  email/password — extracted so BOTH the standalone `SignInView` gate and the
//  onboarding sign-in screen drive the exact same auth flows (unchanged
//  `AuthModel` calls; Apple/Google/email handlers live here, in one place).
//
//  The only thing that differs between the two hosts is how the email option is
//  presented, controlled by `emailStyle`:
//    • `.inline`     — the email form is always visible (the classic gate look).
//    • `.disclosure` — three stacked buttons (Apple, Google, "Continue with
//                      Email"); tapping Email reveals the form. Used by the
//                      onboarding screen 4 spec.
//
//  Errors and the in-flight spinner are owned here so every host handles them
//  identically.
//

import AuthenticationServices
import RecipeKit
import SwiftUI

struct AuthMethodsView: View {
    @ObservedObject var auth: AuthModel
    var emailStyle: EmailStyle = .inline
    var style: Style = .gate

    enum EmailStyle { case inline, disclosure }

    /// Visual styling for the button stack. The gate (`SignInView`) keeps its
    /// original bordered 50pt look; onboarding screen 4 uses taller, borderless
    /// buttons on the `secondaryAuthFill` token and always offers all three
    /// providers so the flow presents a consistent three-button choice.
    struct Style {
        var buttonHeight: CGFloat
        var cornerRadius: CGFloat
        var appleLabel: SignInWithAppleButton.Label
        var providerFill: Color
        var providerBordered: Bool
        var alwaysShowGoogle: Bool

        static let gate = Style(buttonHeight: 50, cornerRadius: 12, appleLabel: .signIn,
                                providerFill: Color.textSecondary.opacity(0.10),
                                providerBordered: true, alwaysShowGoogle: false)
        static let onboarding = Style(buttonHeight: 56, cornerRadius: 16, appleLabel: .continue,
                                      providerFill: Color.secondaryAuthFill,
                                      providerBordered: false, alwaysShowGoogle: true)
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""
    @State private var errorMessage: String?
    @State private var showEmailForm = false
    @StateObject private var google = GoogleSignInControllerBox()

    private enum Mode { case signIn, register }

    var body: some View {
        VStack(spacing: 12) {
            // Native Apple button — height meets the 44pt minimum touch target.
            SignInWithAppleButton(style.appleLabel) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: style.buttonHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .accessibilityLabel("Continue with Apple")

            if AppConfig.isGoogleConfigured || style.alwaysShowGoogle {
                providerButton("Continue with Google", systemImage: "g.circle.fill", action: signInWithGoogle)
            }

            switch emailStyle {
            case .inline:
                dividerRow
                emailForm
            case .disclosure:
                if showEmailForm {
                    emailForm
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    providerButton("Continue with Email", systemImage: "envelope.fill") {
                        withAnimation { showEmailForm = true }
                    }
                }
            }
        }
        .disabled(auth.isWorking)
        .overlay { if auth.isWorking { ProgressView().controlSize(.large) } }
        .alert("Sign-in failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Email form

    private var dividerRow: some View {
        HStack(spacing: 12) {
            line
            Text("or").font(.caption).foregroundStyle(Color.textSecondary)
            line
        }
    }

    private var line: some View { Rectangle().fill(Color.textSecondary.opacity(0.25)).frame(height: 1) }

    /// Subtle field/button fill — the palette has no dedicated surface token, so
    /// this derives one from the text color that reads on the cream background.
    private var fieldFill: Color { Color.textSecondary.opacity(0.10) }

    private var emailForm: some View {
        VStack(spacing: 12) {
            if mode == .register {
                field("Name (optional)", text: $fullName, textContentType: .name)
            }
            field("Email", text: $email, textContentType: .emailAddress, keyboard: .emailAddress)
            secureField("Password", text: $password)

            Button(action: submitEmail) {
                Text(mode == .signIn ? "Sign In" : "Create Account")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(!emailFormValid)
            .opacity(emailFormValid ? 1 : 0.5)

            Button {
                withAnimation { mode = (mode == .signIn ? .register : .signIn) }
            } label: {
                Text(mode == .signIn ? "New here? Create an account" : "Already have an account? Sign in")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.top, 2)
        }
    }

    private func providerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: style.buttonHeight)
            .background(style.providerFill, in: RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay {
                if style.providerBordered {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Color.textSecondary.opacity(0.2))
                }
            }
        }
        .foregroundStyle(Color.textPrimary)
    }

    private func field(_ placeholder: String, text: Binding<String>, textContentType: UITextContentType, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .textContentType(textContentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(fieldFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textContentType(mode == .register ? .newPassword : .password)
            .padding(14)
            .background(fieldFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var emailFormValid: Bool {
        email.contains("@") && password.count >= 8
    }

    // MARK: - Actions (unchanged AuthModel flows)

    private func submitEmail() {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                if mode == .signIn {
                    try await auth.login(email: email, password: password)
                } else {
                    try await auth.register(email: email, password: password, fullName: name.isEmpty ? nil : name)
                }
            } catch {
                present(error)
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple didn’t return a usable credential."
                return
            }
            // Apple provides the name ONLY on the first authorization — capture it now.
            let name = credential.fullName.flatMap { components -> String? in
                let formatted = PersonNameComponentsFormatter().string(from: components)
                return formatted.isEmpty ? nil : formatted
            }
            Task {
                do { try await auth.signInWithApple(identityToken: token, fullName: name) }
                catch { present(error) }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        }
    }

    private func signInWithGoogle() {
        Task {
            do {
                let idToken = try await google.controller.idToken()
                try await auth.signInWithGoogle(idToken: idToken, fullName: nil)
            } catch AuthError.cancelled {
                // user dismissed — no error
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? AuthError)?.userMessage ?? error.localizedDescription
    }
}
