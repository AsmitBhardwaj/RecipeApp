//
//  RecipeListLayoutTests.swift
//  RecipeKitTests
//
//  Locks the rule that the "No recipes yet" empty state never hides a processing
//  or failed card — the regression that made a first share look lost.
//

import XCTest
@testable import RecipeKit

final class RecipeListLayoutTests: XCTestCase {

    func testEmptyStateOnlyWhenNothingToShow() {
        XCTAssertTrue(RecipeListLayout.showsEmptyState(recipeCount: 0, pendingCount: 0, failedCount: 0))
    }

    func testPendingJobSuppressesEmptyState() {
        // The key case: no finished recipes, but a job is processing (first share).
        XCTAssertFalse(RecipeListLayout.showsEmptyState(recipeCount: 0, pendingCount: 1, failedCount: 0))
    }

    func testFailedJobSuppressesEmptyState() {
        XCTAssertFalse(RecipeListLayout.showsEmptyState(recipeCount: 0, pendingCount: 0, failedCount: 1))
    }

    func testExistingRecipesSuppressEmptyState() {
        XCTAssertFalse(RecipeListLayout.showsEmptyState(recipeCount: 3, pendingCount: 0, failedCount: 0))
    }

    func testAnyCombinationOfCardsSuppressesEmptyState() {
        XCTAssertFalse(RecipeListLayout.showsEmptyState(recipeCount: 2, pendingCount: 1, failedCount: 1))
    }
}
