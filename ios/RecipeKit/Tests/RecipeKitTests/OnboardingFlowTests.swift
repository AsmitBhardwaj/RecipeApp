import XCTest
@testable import RecipeKit

final class OnboardingFlowTests: XCTestCase {

    private func freshStore() -> OnboardingFlowStore {
        OnboardingFlowStore(defaults: UserDefaults(suiteName: "onb-\(UUID().uuidString)")!)
    }

    private func route(signedIn: Bool, seen: Bool, done: Bool = false, skipped: Bool = false) -> LaunchRoute {
        OnboardingRouter.route(isSignedIn: signedIn, hasSeenValue: seen, hasCompletedOnboarding: done, skippedQuiz: skipped)
    }

    func testFreshInstallOrderIsValueThenSignInThenQuizThenMain() {
        XCTAssertEqual(route(signedIn: false, seen: false), .value)
        XCTAssertEqual(route(signedIn: false, seen: true), .signIn)            // Value → Continue
        XCTAssertEqual(route(signedIn: true, seen: true), .quiz)               // signed in, quiz owed
        XCTAssertEqual(route(signedIn: true, seen: true, done: true), .main)   // quiz finished
    }

    func testSkipOnValueGoesToSignInThenStraightToMainWithoutQuiz() {
        XCTAssertEqual(route(signedIn: false, seen: true, skipped: true), .signIn)
        XCTAssertEqual(route(signedIn: true, seen: true, skipped: true), .main)
    }

    func testReturningSignedInUserNeverSeesValueOrQuiz() {
        // Even with a cleared/never-set "seen" flag (e.g. an upgrade), signed in → main.
        XCTAssertEqual(route(signedIn: true, seen: false, done: true), .main)
        // A signed-in user still owed the quiz goes to the quiz, not Value.
        XCTAssertEqual(route(signedIn: true, seen: false), .quiz)
    }

    func testSigningOutAndBackInDoesNotShowValueAgain() {
        let store = freshStore()
        store.markValueSeen()                               // first run: Continue
        XCTAssertEqual(route(signedIn: false, seen: store.hasSeenValue), .signIn)   // signed out later
        XCTAssertEqual(route(signedIn: true, seen: store.hasSeenValue, done: true), .main)
    }

    func testStorePersistsSeenAndSkipAcrossInstances() {
        let defaults = UserDefaults(suiteName: "onb-\(UUID().uuidString)")!
        XCTAssertFalse(OnboardingFlowStore(defaults: defaults).hasSeenValue)
        OnboardingFlowStore(defaults: defaults).markValueSeen(skipped: true)
        let reopened = OnboardingFlowStore(defaults: defaults)
        XCTAssertTrue(reopened.hasSeenValue)
        XCTAssertTrue(reopened.skippedQuiz)
        reopened.clearSkip()
        XCTAssertFalse(OnboardingFlowStore(defaults: defaults).skippedQuiz)
        XCTAssertTrue(OnboardingFlowStore(defaults: defaults).hasSeenValue)
    }

    func testContinueDoesNotMarkSkipped() {
        let store = freshStore()
        store.markValueSeen()
        XCTAssertTrue(store.hasSeenValue)
        XCTAssertFalse(store.skippedQuiz)
    }
}

final class ImportTipStoreTests: XCTestCase {
    func testTipShowsUntilDismissedThenNeverAgainForThatUser() {
        let defaults = UserDefaults(suiteName: "tip-\(UUID().uuidString)")!
        let first = ImportTipStore(defaults: defaults, userScope: "u1")
        XCTAssertFalse(first.isDismissed)
        first.dismiss()
        XCTAssertTrue(ImportTipStore(defaults: defaults, userScope: "u1").isDismissed)   // persists across instances
    }

    func testDismissalIsPerUser() {
        let defaults = UserDefaults(suiteName: "tip-\(UUID().uuidString)")!
        ImportTipStore(defaults: defaults, userScope: "u1").dismiss()
        XCTAssertFalse(ImportTipStore(defaults: defaults, userScope: "u2").isDismissed)
    }

    func testAccountEraserClearsTheDismissal() {
        let defaults = UserDefaults(suiteName: "tip-\(UUID().uuidString)")!
        ImportTipStore(defaults: defaults, userScope: "u1").dismiss()
        AccountDataEraser.erase(userId: "u1", defaults: defaults)
        XCTAssertFalse(ImportTipStore(defaults: defaults, userScope: "u1").isDismissed)
    }
}
