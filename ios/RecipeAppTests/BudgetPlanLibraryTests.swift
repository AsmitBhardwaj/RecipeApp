//
//  BudgetPlanLibraryTests.swift
//  RecipeAppTests
//
//  Auto-saving a free plan into the library + "Budget plan" cookbook (no
//  duplicates), swap bookkeeping, and no-overwrite Meal Plan placement — using the
//  real library / cookbook / meal-plan models on an isolated account scope.
//

import XCTest
@testable import RecipeApp
import RecipeKit

@MainActor
final class BudgetPlanLibraryTests: XCTestCase {

    private var scope = ""

    override func setUp() {
        super.setUp()
        scope = "test-\(UUID().uuidString)"
    }

    override func tearDown() {
        AccountDataEraser.erase(userId: scope)
        super.tearDown()
    }

    private func recipe(_ id: String) -> Recipe {
        Recipe(
            recipeId: id, canonicalVideoId: "budget:\(id)", title: "Meal \(id)",
            servings: Servings(amount: 2, unit: nil), prepTimeMinutes: nil, cookTimeMinutes: nil,
            totalTimeMinutes: nil, ingredients: [], instructions: [], confidence: nil,
            sourceType: .generated, imageUrl: nil, imageSource: .none, transcript: nil
        )
    }

    private struct Rig {
        let jobs: PendingJobsModel
        let cookbooks: CookbooksModel
        let mealPlan: MealPlanModel
        let library: BudgetPlanLibrary
    }

    private func makeRig() -> Rig {
        let defaults = UserDefaults(suiteName: "libtests-\(UUID().uuidString)")!
        let jobs = PendingJobsModel(provider: FakeRecipeProvider(), userScope: scope, store: PendingJobStore(defaults: defaults))
        let cookbooks = CookbooksModel(userScope: scope)
        let plan = MealPlanModel(userScope: scope)
        return Rig(jobs: jobs, cookbooks: cookbooks, mealPlan: plan,
                   library: BudgetPlanLibrary(jobs: jobs, cookbooks: cookbooks, mealPlan: plan))
    }

    private var budgetBook: (CookbooksModel) -> Cookbook? { { $0.cookbook(named: BudgetPlanLibrary.cookbookName) } }

    // MARK: Free plan auto-save

    func testFreePlanSavesToLibraryAndBudgetPlanCookbook() {
        let rig = makeRig()
        rig.library.savePlan([recipe("a"), recipe("b"), recipe("c")])

        XCTAssertEqual(Set(rig.jobs.recipes.map(\.recipeId)), ["a", "b", "c"], "appears in All Recipes")
        XCTAssertEqual(Set(RecipeStore(userScope: scope).all().map(\.recipeId)), ["a", "b", "c"], "persisted on disk")
        let book = budgetBook(rig.cookbooks)
        XCTAssertNotNil(book)
        XCTAssertEqual(rig.cookbooks.recipeIds(in: book!.id), ["a", "b", "c"])
    }

    func testSavingTheSamePlanTwiceCreatesNoDuplicates() {
        let rig = makeRig()
        rig.library.savePlan([recipe("a"), recipe("b")])
        rig.library.savePlan([recipe("a"), recipe("b")])

        XCTAssertEqual(rig.jobs.recipes.count, 2)
        XCTAssertEqual(RecipeStore(userScope: scope).all().count, 2)
        XCTAssertEqual(rig.cookbooks.cookbooks.filter { $0.name == "Budget plan" }.count, 1)
        XCTAssertEqual(rig.cookbooks.recipeCount(in: budgetBook(rig.cookbooks)!.id), 2)
    }

    func testReusesAnExistingBudgetPlanCookbook() {
        let rig = makeRig()
        let existing = rig.cookbooks.createCookbook(named: "budget plan")!
        rig.library.savePlan([recipe("a")])
        XCTAssertEqual(rig.cookbooks.cookbooks.count, 1)
        XCTAssertEqual(rig.cookbooks.recipeIds(in: existing.id), ["a"])
    }

    // MARK: Swap bookkeeping

    func testSwapAddsNewRecipeAndRemovesOld() {
        let rig = makeRig()
        rig.library.savePlan([recipe("a"), recipe("b")])
        rig.library.replace(recipe("a"), with: recipe("n"))

        XCTAssertEqual(Set(rig.jobs.recipes.map(\.recipeId)), ["b", "n"])
        XCTAssertEqual(Set(RecipeStore(userScope: scope).all().map(\.recipeId)), ["b", "n"])
        XCTAssertEqual(rig.cookbooks.recipeIds(in: budgetBook(rig.cookbooks)!.id), ["b", "n"])
    }

    func testSwapKeepsOldRecipeIfItsInTheMealPlan() {
        let rig = makeRig()
        rig.library.savePlan([recipe("a")])
        rig.mealPlan.add(recipe: recipe("a"), to: Date(), slot: .dinner)
        rig.library.replace(recipe("a"), with: recipe("n"))

        XCTAssertEqual(Set(rig.jobs.recipes.map(\.recipeId)), ["a", "n"])
        XCTAssertEqual(rig.cookbooks.recipeIds(in: budgetBook(rig.cookbooks)!.id), ["a", "n"], "left untouched")
    }

    func testSwapKeepsOldRecipeIfItsInAnotherCookbook() {
        let rig = makeRig()
        rig.library.savePlan([recipe("a")])
        let mine = rig.cookbooks.createCookbook(named: "Weeknights")!
        rig.cookbooks.addRecipe("a", to: mine.id)
        rig.library.replace(recipe("a"), with: recipe("n"))

        XCTAssertEqual(Set(rig.jobs.recipes.map(\.recipeId)), ["a", "n"])
        XCTAssertEqual(rig.cookbooks.recipeIds(in: mine.id), ["a"])
    }

    // MARK: Meal Plan placement (no overwrite)

    private func dayKeys(_ rig: Rig, of recipeId: String) -> [String] {
        MealPlanStore(userScope: scope).all().filter { $0.recipeId == recipeId }.map(\.dayKey)
    }

    func testWeekAddSkipsDaysThatAlreadyHaveADinner() {
        let rig = makeRig()
        let start = Calendar.current.startOfDay(for: Date())
        let day = { (n: Int) in Calendar.current.date(byAdding: .day, value: n, to: start)! }
        rig.mealPlan.add(recipe: recipe("mine0"), to: day(0), slot: .dinner)
        rig.mealPlan.add(recipe: recipe("mine2"), to: day(2), slot: .dinner)

        rig.mealPlan.addDinners([recipe("a"), recipe("b"), recipe("c")], from: start)

        let key = { MealPlanScheduler.dayKey(for: day($0)) }
        XCTAssertEqual(dayKeys(rig, of: "a"), [key(1)])
        XCTAssertEqual(dayKeys(rig, of: "b"), [key(3)])
        XCTAssertEqual(dayKeys(rig, of: "c"), [key(4)])
        XCTAssertEqual(dayKeys(rig, of: "mine0"), [key(0)], "existing dinners untouched")
        XCTAssertEqual(dayKeys(rig, of: "mine2"), [key(2)])
    }

    func testSingleAddUsesNextOpenDay() {
        let rig = makeRig()
        let start = Calendar.current.startOfDay(for: Date())
        rig.mealPlan.add(recipe: recipe("mine"), to: start, slot: .dinner)
        rig.mealPlan.addDinners([recipe("one")], from: start)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(dayKeys(rig, of: "one"), [MealPlanScheduler.dayKey(for: tomorrow)])
    }

    func testAnotherMealSlotDoesNotBlockADay() {
        let rig = makeRig()
        let start = Calendar.current.startOfDay(for: Date())
        rig.mealPlan.add(recipe: recipe("lunch"), to: start, slot: .lunch)
        rig.mealPlan.addDinners([recipe("one")], from: start)
        XCTAssertEqual(dayKeys(rig, of: "one"), [MealPlanScheduler.dayKey(for: start)])
    }

    func testContainsRecipe() {
        let rig = makeRig()
        XCTAssertFalse(rig.mealPlan.containsRecipe("a"))
        rig.mealPlan.addDinners([recipe("a")])
        XCTAssertTrue(rig.mealPlan.containsRecipe("a"))
    }
}
