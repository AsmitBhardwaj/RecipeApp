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
                providerButton("Continue with Google", icon: { GoogleGLogo(size: 20) }, action: signInWithGoogle)
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
                    providerButton("Continue with Email", icon: { Image(systemName: "envelope.fill") }) {
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

    private func providerButton<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
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

// MARK: - Google "G" mark

/// The official multicolour Google "G", drawn from Google's canonical logo
/// geometry (48×48 viewBox) so it stays crisp at any size and needs no bundled
/// SDK asset. Used on the Google sign-in button in place of a generic glyph.
struct GoogleGLogo: View {
    var size: CGFloat = 20

    // (path data, fill) for the four coloured strokes of the mark.
    private static let strokes: [(String, Color)] = [
        ("M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z",
         Color(red: 0.918, green: 0.263, blue: 0.208)),   // #EA4335 red
        ("M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z",
         Color(red: 0.259, green: 0.522, blue: 0.957)),   // #4285F4 blue
        ("M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z",
         Color(red: 0.984, green: 0.737, blue: 0.020)),   // #FBBC05 yellow
        ("M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z",
         Color(red: 0.204, green: 0.659, blue: 0.325))    // #34A853 green
    ]

    var body: some View {
        ZStack {
            ForEach(0..<GoogleGLogo.strokes.count, id: \.self) { i in
                SVGPath(GoogleGLogo.strokes[i].0).fill(GoogleGLogo.strokes[i].1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Minimal renderer for a 48×48-viewBox SVG path — supports just the commands
/// used by the Google mark (M/m L/l H/h V/v C/c S/s Z), scaled to the frame.
private struct SVGPath: Shape {
    let commands: String
    init(_ d: String) { commands = d }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 48
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var reflection = CGPoint.zero   // reflection of last cubic's 2nd control

        for (cmd, n) in SVGPath.tokenize(commands) {
            let rel = cmd.first!.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                var x = n[0], y = n[1]
                if rel { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y); start = cur
                path.move(to: point(cur.x, cur.y))
                var i = 2
                while i + 1 < n.count {   // extra pairs are implicit line-tos
                    var lx = n[i], ly = n[i + 1]
                    if rel { lx += cur.x; ly += cur.y }
                    cur = CGPoint(x: lx, y: ly); path.addLine(to: point(cur.x, cur.y)); i += 2
                }
            case "L":
                var i = 0
                while i + 1 < n.count {
                    var lx = n[i], ly = n[i + 1]
                    if rel { lx += cur.x; ly += cur.y }
                    cur = CGPoint(x: lx, y: ly); path.addLine(to: point(cur.x, cur.y)); i += 2
                }
            case "H":
                for v in n { var x = v; if rel { x += cur.x }; cur.x = x; path.addLine(to: point(cur.x, cur.y)) }
            case "V":
                for v in n { var y = v; if rel { y += cur.y }; cur.y = y; path.addLine(to: point(cur.x, cur.y)) }
            case "C":
                var i = 0
                while i + 5 < n.count {
                    var c1 = CGPoint(x: n[i], y: n[i + 1])
                    var c2 = CGPoint(x: n[i + 2], y: n[i + 3])
                    var end = CGPoint(x: n[i + 4], y: n[i + 5])
                    if rel {
                        c1.x += cur.x; c1.y += cur.y; c2.x += cur.x; c2.y += cur.y; end.x += cur.x; end.y += cur.y
                    }
                    path.addCurve(to: point(end.x, end.y), control1: point(c1.x, c1.y), control2: point(c2.x, c2.y))
                    reflection = CGPoint(x: 2 * end.x - c2.x, y: 2 * end.y - c2.y)
                    cur = end; i += 6
                }
            case "S":
                var i = 0
                while i + 3 < n.count {
                    var c2 = CGPoint(x: n[i], y: n[i + 1])
                    var end = CGPoint(x: n[i + 2], y: n[i + 3])
                    if rel { c2.x += cur.x; c2.y += cur.y; end.x += cur.x; end.y += cur.y }
                    let c1 = reflection   // first control mirrors the previous curve
                    path.addCurve(to: point(end.x, end.y), control1: point(c1.x, c1.y), control2: point(c2.x, c2.y))
                    reflection = CGPoint(x: 2 * end.x - c2.x, y: 2 * end.y - c2.y)
                    cur = end; i += 4
                }
            case "Z":
                path.closeSubpath(); cur = start
            default:
                break
            }
        }
        return path
    }

    /// Split a path string into (command, numbers) groups.
    private static func tokenize(_ d: String) -> [(String, [CGFloat])] {
        let commandSet = Set("MmLlHhVvCcSsZz")
        var result: [(String, [CGFloat])] = []
        var currentCmd: Character?
        var numbers: [CGFloat] = []
        func flush() { if let c = currentCmd { result.append((String(c), numbers)); numbers = [] } }

        var i = d.startIndex
        while i < d.endIndex {
            let ch = d[i]
            if commandSet.contains(ch) {
                flush(); currentCmd = ch; numbers = []; i = d.index(after: i)
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                i = d.index(after: i)
            } else {
                var s = ""
                if ch == "-" || ch == "+" { s.append(ch); i = d.index(after: i) }
                var seenDot = false
                while i < d.endIndex {
                    let c = d[i]
                    if c.isNumber { s.append(c); i = d.index(after: i) }
                    else if c == "." && !seenDot { seenDot = true; s.append(c); i = d.index(after: i) }
                    else { break }
                }
                if let v = Double(s) { numbers.append(CGFloat(v)) }
            }
        }
        flush()
        return result
    }
}
