//
//  FeedbackView.swift
//  RecipeApp
//
//  "Send Feedback" — a star rating + comments + optional email. Submits to the
//  backend (POST /feedback) via the same APIRecipeProvider header/abuse-prevention
//  path as everything else. On success shows a brief confirmation and dismisses;
//  on failure reuses the app's FailureAlertView modal.
//

import SwiftUI
import RecipeKit

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rating = 0
    @State private var message = ""
    @State private var email = ""
    @State private var phase: Phase = .editing
    @State private var failureMessage: String?

    private enum Phase { case editing, submitting, success }

    /// Enabled once there's something to send — a rating OR text (not both).
    private var canSubmit: Bool {
        rating > 0 || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if phase == .success {
                successState
            } else {
                form
            }
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Send Feedback")
                    .font(.editorialTitle(size: 20))
                    .foregroundStyle(Color.textPrimary)
            }
        }
        .overlay {
            if let failureMessage {
                FailureAlertView(title: "Couldn't send feedback 😕", message: failureMessage) {
                    self.failureMessage = nil
                }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card {
                    Text("How's it going?").font(.headline)
                    StarRating(rating: $rating)
                        .padding(.top, 2)
                }

                card {
                    Text("Comments").font(.headline)
                    TextField("What's working, what's not…", text: $message, axis: .vertical)
                        .lineLimit(4...8)
                        .font(.body)
                }

                card {
                    Text("Email").font(.headline)
                    Text("Leave your email if you'd like a reply — optional.")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    TextField("you@example.com", text: $email)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }

                submitButton
                    .padding(.top, 4)
            }
            .padding(20)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tornEdgeCard()
    }

    private var submitButton: some View {
        Button(action: submit) {
            Group {
                if phase == .submitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Submit")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                canSubmit ? Color.accentColor : Color.textSecondary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || phase == .submitting)
    }

    // MARK: Success

    private var successState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Thanks for your feedback!")
                .font(.editorialTitle(size: 24, relativeTo: .title))
                .multilineTextAlignment(.center)
            Text("We read every note.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        }
    }

    // MARK: Submit

    private func submit() {
        phase = .submitting
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        Task { @MainActor in
            do {
                try await APIRecipeProvider().submitFeedback(
                    rating: rating > 0 ? rating : nil,
                    message: trimmedMessage.isEmpty ? nil : trimmedMessage,
                    contactEmail: trimmedEmail.isEmpty ? nil : trimmedEmail,
                    appVersion: version
                )
                phase = .success
            } catch let error as RecipeProviderError {
                phase = .editing
                failureMessage = error.userMessage
            } catch {
                phase = .editing
                failureMessage = "Something went wrong sending your feedback. Please try again."
            }
        }
    }
}

// MARK: - Star rating control

struct StarRating: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(index <= rating ? Color.secondaryAccent : Color.textSecondary.opacity(0.5))
                    .onTapGesture {
                        // Tapping the current rating clears it (back to none).
                        rating = (rating == index) ? 0 : index
                    }
                    .accessibilityLabel("\(index) star\(index == 1 ? "" : "s")")
            }
        }
    }
}

#Preview {
    NavigationStack {
        FeedbackView()
    }
}
