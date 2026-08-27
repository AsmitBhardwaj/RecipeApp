//
//  SignInView.swift
//  RecipeApp
//
//  The mandatory account gate (Stage 3): Sign in with Apple, Google, and
//  email/password. Shown after onboarding until the user is signed in. Apple is
//  native (no dependency); Google runs the OAuth flow in GoogleSignInController;
//  email/password posts to the backend directly.
//

import AuthenticationServices
import RecipeKit
import SwiftUI

struct SignInView: View {
    @ObservedObject var auth: AuthModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""
    @State private var errorMessage: String?
    @StateObject private var google = GoogleSignInControllerBox()

    private enum Mode { case signIn, register }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if AppConfig.isGoogleConfigured {
                        providerButton("Continue with Google", systemImage: "g.circle.fill", action: signInWithGoogle)
                    }
                }

                dividerRow

                emailForm

                Text("By continuing you agree to our Terms and Privacy Policy.")
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .disabled(auth.isWorking)
        .overlay { if auth.isWorking { ProgressView().controlSize(.large) } }
        .alert("Sign-in failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("Welcome")
                .font(.editorialTitle(size: 34))
            Text("Create an account or sign in to save your recipes and sync them across your devices.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

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
            .frame(height: 50)
            .background(fieldFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.textSecondary.opacity(0.2)))
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

    // MARK: - Actions

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

/// Keeps the (non-ObservableObject) Google controller alive for the view's
/// lifetime without recreating it each render.
@MainActor
final class GoogleSignInControllerBox: ObservableObject {
    let controller = GoogleSignInController()
}
