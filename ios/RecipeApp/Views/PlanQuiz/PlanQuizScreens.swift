//
//  PlanQuizScreens.swift
//  RecipeApp
//
//  The six quiz screens' content: People, Diet, Food mood, Appliances (an
//  interactive kitchen picture), Store, Budget. Each is bound to a
//  `PlanQuizModel`; all rules (exclusivity, the mood cap, budget bounds) live in
//  RecipeKit's `PlanQuizSession` so they're unit-tested.
//

import RecipeKit
import SwiftUI
import UIKit

// MARK: - People

struct QuizPeopleContent: View {
    @ObservedObject var model: PlanQuizModel

    var body: some View {
        let selected = PlanPeopleChoice.option(forHouseholdSize: model.session.draft.householdSize)
        VStack(spacing: 12) {
            ForEach(PlanPeopleChoice.options, id: \.self) { count in
                QuizOptionRow(title: PlanPeopleChoice.label(for: count), isSelected: selected == count, mark: .radio) {
                    model.session.selectPeople(count)
                }
            }
        }
    }
}

// MARK: - Diet

struct QuizDietContent: View {
    @ObservedObject var model: PlanQuizModel

    var body: some View {
        VStack(spacing: 12) {
            ForEach(DietaryPreference.allCases, id: \.self) { preference in
                QuizOptionRow(
                    title: preference.displayName,
                    isSelected: model.session.draft.dietaryPreferences.contains(preference),
                    mark: .checkbox
                ) { model.session.toggleDiet(preference) }
            }
            Text("These choices guide recommendations and are not medical guarantees.")
                .font(.footnote)
                .foregroundStyle(QuizStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}

// MARK: - Food mood

struct QuizMoodContent: View {
    @ObservedObject var model: PlanQuizModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let selected = model.session.draft.foodMoods
        let atMax = selected.count >= FoodMood.maxSelection
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(FoodMood.allCases, id: \.self) { mood in
                let isSelected = selected.contains(mood)
                MoodCard(mood: mood, isSelected: isSelected, isBlocked: atMax && !isSelected) {
                    if !model.session.toggleMood(mood) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        UIAccessibility.post(notification: .announcement, argument: "You can pick up to three")
                    }
                }
            }
        }
    }
}

private struct MoodCard: View {
    let mood: FoodMood
    let isSelected: Bool
    let isBlocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                QuizAssetImage(name: mood.assetName, cornerRadius: 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .clipped()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mood.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(mood.blurb)
                        .font(.system(size: 13))
                        .foregroundStyle(QuizStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(QuizSelectionSurface(isSelected: isSelected, radius: 18))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: Circle())
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .opacity(isBlocked ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mood.title). \(mood.blurb)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isBlocked ? "You can pick up to three" : "")
    }
}

// MARK: - Appliances

struct QuizAppliancesContent: View {
    @ObservedObject var model: PlanQuizModel
    @State private var showList = false

    var body: some View {
        let selected = model.session.draft.appliances
        VStack(alignment: .leading, spacing: 16) {
            if showList {
                VStack(spacing: 12) {
                    ForEach(Appliance.allCases, id: \.self) { appliance in
                        QuizOptionRow(title: appliance.title, isSelected: selected.contains(appliance), mark: .checkbox) {
                            model.session.toggleAppliance(appliance)
                        }
                    }
                }
            } else {
                KitchenPicture(selected: selected) { model.session.toggleAppliance($0) }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(summary(selected))
                    .font(.system(size: 15))
                    .foregroundStyle(QuizStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(summary(selected))
                Spacer(minLength: 0)
                Button(showList ? "Use the picture" : "Use a list") {
                    withAnimation(.easeInOut(duration: 0.2)) { showList.toggle() }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
                .accessibilityHint(showList ? "Shows the kitchen picture" : "Shows the appliances as a list")
            }
        }
    }

    /// "3 selected · Stovetop, Oven, Kettle"
    private func summary(_ selected: Set<Appliance>) -> String {
        let names = Appliance.allCases.filter(selected.contains).map(\.title)
        return names.isEmpty ? "0 selected" : "\(names.count) selected · \(names.joined(separator: ", "))"
    }
}

/// The interactive kitchen picture: `kitchen_scene` at a fixed aspect ratio in a
/// rounded card, with one tappable hotspot per appliance placed from the single
/// normalized-rect table in RecipeKit (`KitchenHotspots.table`) so it scales on
/// every device. Until the art lands the card shows the tinted fallback with each
/// hotspot's name so the placeholder rects can be checked.
struct KitchenPicture: View {
    let selected: Set<Appliance>
    let onToggle: (Appliance) -> Void

    private let hasArt = QuizAssetImage.exists("kitchen_scene")
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                QuizAssetImage(name: "kitchen_scene", cornerRadius: 0)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .accessibilityHidden(true)
                ForEach(KitchenHotspots.table, id: \.appliance) { spot in
                    hotspot(spot, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .aspectRatio(CGFloat(KitchenHotspots.imageAspectRatio), contentMode: .fit)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.hairline, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your kitchen")
    }

    @ViewBuilder
    private func hotspot(_ spot: KitchenHotspots.Hotspot, in size: CGSize) -> some View {
        let frame = spot.rect.frame(in: size)
        let isOn = selected.contains(spot.appliance)
        // Keep every tap target at least 44pt, centered on the art's rect.
        let hitW = max(frame.width, 44)
        let hitH = max(frame.height, 44)

        Button { onToggle(spot.appliance) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.12) : Color.clear)
                    .frame(width: frame.width, height: frame.height)
                if isOn {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .frame(width: frame.width, height: frame.height)
                        .shadow(color: Color.accentColor.opacity(0.65), radius: 7)
                } else {
                    if !hasArt {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: frame.width, height: frame.height)
                        Text(spot.appliance.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(QuizStyle.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 2)
                    }
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(Color.appBackground, in: Circle())
                        .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 1) }
                        .offset(x: frame.width / 2 - 14, y: -frame.height / 2 + 14)
                }
            }
            .frame(width: hitW, height: hitH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel(spot.appliance.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityHint(isOn ? "Double tap to remove" : "Double tap to add")

        if isOn {
            Text(spot.appliance.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Color.appBackground, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1) }
                .position(x: frame.midX, y: min(frame.maxY + 12, size.height - 11))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Store

struct QuizStoreContent: View {
    @ObservedObject var model: PlanQuizModel
    @State private var showingCountryPicker = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var countryBinding: Binding<String?> {
        Binding(get: { model.session.draft.country }, set: { model.session.setCountry($0) })
    }

    private var countryName: String {
        model.session.draft.country.flatMap { GroceryCountry.localizedName(for: $0) } ?? "Not set"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { showingCountryPicker = true } label: {
                HStack(spacing: 6) {
                    Text("Country: \(countryName)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("·").foregroundStyle(QuizStyle.secondaryText)
                    Text("Change")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Country, \(countryName)")
            .accessibilityHint("Change country")

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PlanStore.all, id: \.name) { store in
                    StoreTile(store: store, isSelected: model.session.draft.storeName == store.name) {
                        model.session.selectStore(store)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCountryPicker) {
            CountryPickerSheet(selection: countryBinding)
        }
    }
}

private struct StoreTile: View {
    let store: PlanStore
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(store.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                Text(store.priceHint.isEmpty ? " " : store.priceHint)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuizStyle.secondaryText)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 76)
            .modifier(QuizSelectionSurface(isSelected: isSelected, radius: QuizStyle.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Budget

struct QuizBudgetContent: View {
    @ObservedObject var model: PlanQuizModel

    var body: some View {
        let session = model.session
        let bounds = session.budgetBounds
        let budget = session.budget
        VStack(spacing: 24) {
            HStack(spacing: 20) {
                stepButton("minus", label: "Decrease budget by 5 dollars", enabled: budget > bounds.lowerBound) {
                    model.session.stepBudget(by: -1)
                }
                Text("$\(budget)")
                    .font(.editorialTitle(size: 56, relativeTo: .largeTitle))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(minWidth: 130)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: budget)
                    .accessibilityLabel("Weekly budget, \(budget) dollars")
                stepButton("plus", label: "Increase budget by 5 dollars", enabled: budget < bounds.upperBound) {
                    model.session.stepBudget(by: 1)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(model.session.budget) },
                        set: { model.session.setBudget(Int($0.rounded())) }
                    ),
                    in: Double(bounds.lowerBound)...Double(bounds.upperBound),
                    step: Double(PlanBudgetHelper.increment)
                )
                .tint(Color.accentColor)
                .accessibilityLabel("Weekly budget")
                .accessibilityValue("\(budget) dollars")
                HStack {
                    Text("$\(bounds.lowerBound)")
                    Spacer()
                    Text("$\(bounds.upperBound)")
                }
                .font(.system(size: 13))
                .foregroundStyle(QuizStyle.secondaryText)
                .accessibilityHidden(true)
            }

            helperCard(session)
        }
    }

    private func helperCard(_ session: PlanQuizSession) -> some View {
        let text = PlanBudgetHelper.helperText(
            people: session.draft.householdSize,
            storeName: session.draft.store?.helperName ?? "your store",
            spend: session.typicalSpend
        )
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuizStyle.selectedFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : QuizStyle.secondaryText)
                .frame(width: 52, height: 52)
                .background(enabled ? Color.accentColor : Color.hairline, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
