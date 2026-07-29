//
//  MealPlanView.swift
//  RecipeApp
//
//  The Meal Plan tab: a navigable Monday–Sunday week. Each day holds a flat list
//  of assigned recipes (no named meal slots). Tapping "Add" on a day presents a
//  picker of the user's existing extracted recipes; assignments show as compact
//  rows and can be swiped away.
//
//  Recipes for the picker come from `PendingJobsModel.recipes` (read-only). The
//  plan itself is owned by `MealPlanModel`, backed by the local `MealPlanStore`.
//

import SwiftUI
import RecipeKit

struct MealPlanView: View {
    @ObservedObject var jobs: PendingJobsModel
    @StateObject private var plan = MealPlanModel()

    /// The day the user is currently assigning a recipe to (drives the sheet).
    @State private var assigningDay: AssigningDay?

    var body: some View {
        VStack(spacing: 0) {
            WeekSwitcherBar(plan: plan)
            Divider()
            dayList
        }
        .foregroundStyle(Color.textPrimary)
        .appBackground()
        .navigationTitle("Meal Plan")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $assigningDay) { day in
            RecipePickerSheet(recipes: jobs.recipes) { recipe in
                plan.add(recipe: recipe, to: day.date)
                assigningDay = nil
            }
        }
    }

    private var dayList: some View {
        List {
            ForEach(plan.weekDays, id: \.self) { day in
                Section {
                    let entries = plan.entries(for: day)
                    if entries.isEmpty {
                        Text("Nothing planned")
                            .font(.subheadline)
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        ForEach(entries) { entry in
                            MealPlanEntryRow(entry: entry)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        plan.remove(entry)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }

                    Button {
                        assigningDay = AssigningDay(date: day, key: plan.dayKey(for: day))
                    } label: {
                        Label("Add recipe", systemImage: "plus")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                } header: {
                    DayHeader(date: day, isToday: plan.isToday(day))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Sheet item

/// Identifiable wrapper so `.sheet(item:)` can key on the day being assigned.
private struct AssigningDay: Identifiable {
    let date: Date
    let key: String
    var id: String { key }
}

// MARK: - Week switcher

private struct WeekSwitcherBar: View {
    @ObservedObject var plan: MealPlanModel

    var body: some View {
        HStack {
            Button {
                plan.goToPreviousWeek()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.tint)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(rangeText)
                    .font(.headline)
                if !plan.isCurrentWeek {
                    Button("This Week") { plan.goToThisWeek() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }

            Spacer()

            Button {
                plan.goToNextWeek()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var rangeText: String {
        guard let first = plan.weekDays.first, let last = plan.weekDays.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let start = f.string(from: first)
        // Include the year on the end date for context across week navigation.
        f.dateFormat = "MMM d, yyyy"
        let end = f.string(from: last)
        return "\(start) – \(end)"
    }
}

// MARK: - Day header

private struct DayHeader: View {
    let date: Date
    let isToday: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(weekdayText)
            if isToday {
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondaryAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private var weekdayText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}

// MARK: - Assigned recipe row

private struct MealPlanEntryRow: View {
    let entry: MealPlanEntry

    var body: some View {
        HStack(spacing: 12) {
            RecipeImageView(imageUrl: entry.recipeImageURL, placeholderSymbolSize: 16)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(entry.recipeTitle)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Recipe picker sheet

private struct RecipePickerSheet: View {
    let recipes: [Recipe]
    let onPick: (Recipe) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No recipes yet", systemImage: "book.closed")
                    } description: {
                        Text("Add recipes in the Recipes tab first, then assign them here.")
                    }
                } else {
                    List(recipes) { recipe in
                        Button {
                            onPick(recipe)
                        } label: {
                            RecipeRowView(recipe: recipe)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .foregroundStyle(Color.textPrimary)
            .appBackground()
            .navigationTitle("Add to day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MealPlanView(jobs: PendingJobsModel(provider: MockRecipeProvider()))
    }
}
