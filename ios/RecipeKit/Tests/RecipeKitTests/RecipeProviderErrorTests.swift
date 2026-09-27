//
//  RecipeProviderErrorTests.swift
//  RecipeKitTests
//
//  `RecipeProviderError.canPasteText` is the single source of truth the app
//  reads from two places: `PendingJobsModel.FailedJob.canPasteText` (the
//  persistent failed-job card) and `PendingJobsModel.FailureAlert.canPasteText`
//  (the one-time failure alert). Both just forward to this function, so
//  covering it here covers "paste-eligible failure exposes the paste action;
//  non-eligible doesn't" at the single seam that decides it.
//

import XCTest
@testable import RecipeKit

final class RecipeProviderErrorTests: XCTestCase {

    func testPasteEligibleCodesExposePasteAction() {
        for code in RecipeProviderError.pasteEligibleCodes {
            XCTAssertTrue(
                RecipeProviderError.canPasteText(code: code),
                "\(code) is in pasteEligibleCodes but canPasteText returned false"
            )
        }
    }

    func testNonEligibleCodeDoesNotExposePasteAction() {
        let nonEligible = ["no_recipe_found", "blocked_host", "invalid_url", "unknown_error", "llm_refusal"]
        for code in nonEligible {
            XCTAssertFalse(
                RecipeProviderError.canPasteText(code: code),
                "\(code) should not be paste-eligible"
            )
        }
    }

    func testNilCodeDoesNotExposePasteAction() {
        XCTAssertFalse(RecipeProviderError.canPasteText(code: nil))
    }
}
