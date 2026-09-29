//
//  PlanPreferencesEditorView.swift
//  RecipeApp
//
//  Account → Plan preferences: the six quiz answers as a list; each row opens the
//  same screen the quiz uses (pre-filled) and saves on Continue.
//

import RecipeKit
import SwiftUI

extension PlanQuizStep: Identifiable {
    public var id: String { rawValue }
}

struct PlanPreferencesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: CookingPreferencesModel

    @State private var editing: PlanQuizStep?
    @State private var editor: PlanQuizModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plan preferences")
                    .font(.editorialTitle(size: 28, relativeTo: .title))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(PlanQuizStep.onboarding.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.leading, 20) }
                        row(step)
                    }
                }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .foregroundStyle(Color.textPrimary)
        .fullScreenCover(item: $editing) { _ in
            if let editor {
                PlanQuizFlow(model: editor, onExit: { editing = nil }, onFinish: { draft in
                    preferences.save(draft)
                    editing = nil
                })
            }
        }
    }

    private func row(_ step: PlanQuizStep) -> some View {
        Button {
            editor = PlanQuizModel(session: .edit(
                step, from: preferences.preferences, deviceCountry: GroceryCountry.guessFromLocale()
            ))
            editing = step
        } label: {
            HStack(spacing: 12) {
                Text(step.editorTitle)
                    .font(.system(size: 16, weight: .medium))
                Spacer(minLength: 12)
                Text(summary(step))
                    .font(.system(size: 15))
                    .foregroundStyle(QuizStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.editorTitle), \(summary(step))")
        .accessibilityHint("Opens this question")
    }

    private func summary(_ step: PlanQuizStep) -> String {
        let p = preferences.preferences
        switch step {
        case .people:
            return PlanPeopleChoice.label(for: PlanPeopleChoice.option(forHouseholdSize: p.householdSize))
        case .diet:
            let names = DietaryPreference.allCases.filter(p.dietaryPreferences.contains).map(\.displayName)
            return names.isEmpty ? "No restrictions" : names.joined(separator: ", ")
        case .mood:
            let names = p.orderedFoodMoods.map(\.title)
            return names.isEmpty ? "Any" : names.joined(separator: ", ")
        case .appliances:
            let names = p.orderedAppliances.map(\.title)
            return names.isEmpty ? "Not set" : names.joined(separator: ", ")
        case .store:
            return p.storeName ?? "Not set"
        case .budget:
            return p.weeklyBudget.map { "$\($0) / week" } ?? "Not set"
        }
    }
}
