//
//  AddToKitchenSheet.swift
//  RecipeApp
//
//  Custom bottom-sheet for the Kitchen tab's "Add to kitchen" flow, replacing the
//  old system UIAlertController. Matches the app's card system: theme-aware
//  surface (cream in light / dark-brown in dark via `Color.appBackground`), a
//  22pt top-corner radius, a centered drag-handle pill, a serif title and muted
//  subtitle, the app's pill-style text field, and side-by-side muted / sage CTAs.
//
//  Presentation only. `onAdd` is the exact same call the alert made
//  (`PantryModel.add`); this view never touches the sync collection itself. The
//  type-ahead is a local convenience over `IngredientCatalog` (a bundled static
//  list) — tapping a suggestion only fills the field; the user still taps Add,
//  and free text the catalog doesn't know is submitted unchanged.
//
//  Why a custom overlay instead of `.presentationDetents`: the suggestion list
//  AND the action buttons sit BELOW the focused field, and must stay above the
//  keyboard on every device size. A sheet detent keeps the focused field visible
//  but not content beneath it, so we drive our own keyboard-height offset here.
//

import SwiftUI

extension View {
    /// Presents the custom "Add to kitchen" sheet as a full-screen cover with a
    /// clear background, so this view owns the scrim, corner radius, and drag
    /// handle (a plain `.sheet` can't). `onAdd` receives the submitted text.
    func addToKitchenSheet(isPresented: Binding<Bool>, onAdd: @escaping (String) -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) {
            AddToKitchenSheet(isPresented: isPresented, onAdd: onAdd)
                .presentationBackground(.clear)
        }
    }
}

struct AddToKitchenSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void

    @State private var text = ""
    /// Drives the fade/slide so scrim + card animate together on show and dismiss
    /// (independent of the cover's own transition, which is invisible thanks to
    /// the clear background).
    @State private var revealed = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    private let catalog = IngredientCatalog.shared

    /// Prefix matches for the current text (empty until the user types).
    private var suggestions: [String] {
        catalog.matches(prefix: text, limit: 6)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim — tap outside the card to dismiss.
            Color.black
                .opacity(revealed ? 0.4 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            card
                .offset(y: revealed ? 0 : 40)
                .opacity(revealed ? 1 : 0)
                // Own the keyboard inset ourselves so the WHOLE card (field +
                // suggestions + buttons) rides above the keyboard on every size.
                .padding(.bottom, keyboardHeight)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { revealed = true }
            // Slight delay so focus (and the keyboard) animate in after the card.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let screen = UIScreen.main.bounds
            // Height of the keyboard's intrusion into the screen (0 when hidden).
            let overlap = max(0, screen.maxY - frame.minY)
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = overlap }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 16) {
            dragHandle

            VStack(spacing: 4) {
                Text("Add to kitchen")
                    .font(.editorialTitle(size: 24))
                    .foregroundStyle(Color.textPrimary)
                Text("Add something you have on hand.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            field

            if !suggestions.isEmpty {
                suggestionList
            }

            buttons
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(
            Color.appBackground,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22
            )
        )
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.textSecondary.opacity(0.4))
            .frame(width: 40, height: 5)
            .accessibilityHidden(true)
    }

    // MARK: - Pill text field (matches SignInView's field treatment)

    private var field: some View {
        TextField("e.g. olive oil", text: $text)
            .font(.body)
            .foregroundStyle(Color.textPrimary)      // cream text in dark mode
            .tint(Color.accentColor)                 // sage cursor / selection
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($fieldFocused)
            .onSubmit(add)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.textSecondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.textSecondary.opacity(0.15))
            )
    }

    // MARK: - Type-ahead suggestions

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                Button {
                    // Fill only — do NOT auto-submit; the user still taps Add.
                    text = name
                    fieldFocused = true
                } label: {
                    HStack {
                        highlighted(name)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < suggestions.count - 1 {
                    Divider().overlay(Color.textSecondary.opacity(0.12))
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// A suggestion with its matched prefix accented in sage, the remainder in the
    /// primary text color. Uses the suggestion's own casing for both parts.
    private func highlighted(_ name: String) -> Text {
        let prefixLen = min(trimmed.count, name.count)
        let matched = String(name.prefix(prefixLen))
        let rest = String(name.dropFirst(prefixLen))
        return Text(matched)
            .foregroundColor(Color.accentColor)
            .fontWeight(.semibold)
            + Text(rest)
            .foregroundColor(Color.textPrimary)
    }

    // MARK: - Actions (full-width, side by side)

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: dismiss) {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.textPrimary)
                    .background(Color.textSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button(action: add) {
                Text("Add")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.5 : 1)
        }
    }

    // MARK: - Behavior

    private func add() {
        guard !trimmed.isEmpty else { return }
        onAdd(text)          // same payload the old alert passed through
        dismiss()
    }

    private func dismiss() {
        fieldFocused = false
        withAnimation(.easeIn(duration: 0.2)) {
            revealed = false
            keyboardHeight = 0
        }
        // Let the fade/slide finish before tearing down the cover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            text = ""
            isPresented = false
        }
    }
}

#Preview {
    struct Host: View {
        @State private var showing = true
        var body: some View {
            Color.appBackground.ignoresSafeArea()
                .addToKitchenSheet(isPresented: $showing) { _ in }
        }
    }
    return Host()
}
