import XCTest
@testable import RecipeKit

final class IngredientTextFormatterTests: XCTestCase {
    func testStructuredQuantityAndUnit() {
        assertParts(
            IngredientTextFormatter.parts(
                for: Ingredient(quantity: 14, unit: "oz", name: "tomato", notes: "diced")
            ),
            measurement: "14 oz",
            remainder: " tomato (diced)"
        )
    }

    func testStructuredSizeDescriptorWithoutUnit() {
        assertParts(
            IngredientTextFormatter.parts(
                for: Ingredient(quantity: 1, unit: nil, name: "large onion", notes: nil)
            ),
            measurement: "1 large",
            remainder: " onion"
        )
    }

    func testScaledIngredientUsesDisplayedFraction() {
        assertParts(
            IngredientTextFormatter.parts(
                for: Ingredient(quantity: 1, unit: "cup", name: "flour", notes: nil),
                scaledBy: 1.5
            ),
            measurement: "1½ cup",
            remainder: " flour"
        )
    }

    func testRawNumberFormatsAndRanges() {
        let cases: [(String, String, String)] = [
            ("2 tbsp oil", "2 tbsp", " oil"),
            ("0.5 kg potatoes", "0.5 kg", " potatoes"),
            ("1/2 lb ground beef", "1/2 lb", " ground beef"),
            ("½ cup milk", "½ cup", " milk"),
            ("1 1/2 cups flour", "1 1/2 cups", " flour"),
            ("1–2 tbsp sugar", "1–2 tbsp", " sugar"),
        ]

        for (line, measurement, remainder) in cases {
            assertParts(
                IngredientTextFormatter.parts(in: line),
                measurement: measurement,
                remainder: remainder,
                file: #filePath,
                line: #line
            )
        }
    }

    func testQuantityWithoutAUnitDoesNotBoldIngredientName() {
        assertParts(
            IngredientTextFormatter.parts(in: "2 chicken breasts"),
            measurement: "2",
            remainder: " chicken breasts"
        )
    }

    func testUnquantifiedIngredientRemainsRegular() {
        assertParts(
            IngredientTextFormatter.parts(in: "salt to taste"),
            measurement: nil,
            remainder: "salt to taste"
        )
    }

    private func assertParts(
        _ parts: IngredientTextParts,
        measurement: String?,
        remainder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(parts.measurement, measurement, file: file, line: line)
        XCTAssertEqual(parts.remainder, remainder, file: file, line: line)
    }
}
