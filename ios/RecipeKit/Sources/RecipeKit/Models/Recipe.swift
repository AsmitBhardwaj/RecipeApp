//
//  Recipe.swift
//  RecipeKit
//
//  Swift mirror of the backend Pydantic models in `app/models.py`. Moved here
//  from the app target so the app and the future Share Extension share ONE
//  source of truth instead of duplicating the shapes.
//
//  These are `Codable` with explicit snake_case `CodingKeys`, so real JSON from
//  the API decodes into them without any decoder key-strategy configuration.
//  Optionality matches the Python `Optional[...]` fields exactly so real data
//  containing nulls decodes cleanly instead of throwing.
//
//  Everything is `public` (with explicit `public` initializers) because a public
//  struct's memberwise init is otherwise internal — the app target constructs
//  these directly for its mock/sample data.
//

import Foundation

// MARK: - Recipe

/// Mirror of backend `Recipe` (app/models.py §4).
public struct Recipe: Codable, Identifiable, Hashable {
    public let recipeId: String
    public let canonicalVideoId: String
    public let title: String
    public let servings: Servings
    public let prepTimeMinutes: Double?
    public let cookTimeMinutes: Double?
    public let totalTimeMinutes: Double?
    public let ingredients: [Ingredient]
    public let instructions: [Instruction]
    /// Present on the backend and drives future confidence-based UI treatment
    /// (CLAUDE.md §5). Optional here because it is not needed for this pass.
    public let confidence: Confidence?
    public let sourceType: SourceType
    public let imageUrl: String?
    public let imageSource: ImageSource

    /// Future-facing nullable field (CLAUDE.md §8). Always null today.
    public let transcript: String?

    // NOTE: The backend `Recipe` also carries a freeform `nutrition` dict
    // (always null today). It is intentionally omitted here: `Codable` ignores
    // unknown JSON keys, so decoding stays lossless, and we will add a typed
    // model for it when the nutrition feature actually lands rather than
    // pulling in an `AnyCodable` helper prematurely.

    public var id: String { recipeId }

    public init(
        recipeId: String,
        canonicalVideoId: String,
        title: String,
        servings: Servings,
        prepTimeMinutes: Double?,
        cookTimeMinutes: Double?,
        totalTimeMinutes: Double?,
        ingredients: [Ingredient],
        instructions: [Instruction],
        confidence: Confidence?,
        sourceType: SourceType,
        imageUrl: String?,
        imageSource: ImageSource,
        transcript: String?
    ) {
        self.recipeId = recipeId
        self.canonicalVideoId = canonicalVideoId
        self.title = title
        self.servings = servings
        self.prepTimeMinutes = prepTimeMinutes
        self.cookTimeMinutes = cookTimeMinutes
        self.totalTimeMinutes = totalTimeMinutes
        self.ingredients = ingredients
        self.instructions = instructions
        self.confidence = confidence
        self.sourceType = sourceType
        self.imageUrl = imageUrl
        self.imageSource = imageSource
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case recipeId = "recipe_id"
        case canonicalVideoId = "canonical_video_id"
        case title
        case servings
        case prepTimeMinutes = "prep_time_minutes"
        case cookTimeMinutes = "cook_time_minutes"
        case totalTimeMinutes = "total_time_minutes"
        case ingredients
        case instructions
        case confidence
        case sourceType = "source_type"
        case imageUrl = "image_url"
        case imageSource = "image_source"
        case transcript
    }
}

// MARK: - Servings

/// Mirror of backend `Servings` — both fields optional.
public struct Servings: Codable, Hashable {
    public let amount: Double?
    public let unit: String?

    public init(amount: Double?, unit: String?) {
        self.amount = amount
        self.unit = unit
    }
}

// MARK: - Ingredient

/// Mirror of backend `Ingredient`. Only `name` is required; the rest optional.
public struct Ingredient: Codable, Hashable {
    public let quantity: Double?
    public let unit: String?
    public let name: String
    public let notes: String?

    public init(quantity: Double?, unit: String?, name: String, notes: String?) {
        self.quantity = quantity
        self.unit = unit
        self.name = name
        self.notes = notes
    }
}

// MARK: - Instruction

/// Mirror of backend `Instruction`. `stepNumber` is unique per recipe, so it
/// doubles as a stable `Identifiable` id for `ForEach`.
public struct Instruction: Codable, Hashable, Identifiable {
    public let stepNumber: Int
    public let text: String

    public var id: Int { stepNumber }

    public init(stepNumber: Int, text: String) {
        self.stepNumber = stepNumber
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case stepNumber = "step_number"
        case text
    }
}

// MARK: - Confidence

/// Mirror of backend `Confidence` (app/models.py §5).
public struct Confidence: Codable, Hashable {
    public let overall: Double
    public let ingredientsComplete: Bool
    public let instructionsComplete: Bool
    public let missingFields: [String]

    public init(overall: Double, ingredientsComplete: Bool, instructionsComplete: Bool, missingFields: [String]) {
        self.overall = overall
        self.ingredientsComplete = ingredientsComplete
        self.instructionsComplete = instructionsComplete
        self.missingFields = missingFields
    }

    enum CodingKeys: String, CodingKey {
        case overall
        case ingredientsComplete = "ingredients_complete"
        case instructionsComplete = "instructions_complete"
        case missingFields = "missing_fields"
    }
}

// MARK: - Enums (decode defensively)

/// Backend `source_type` (Literal["caption", "generated"]). Decodes an unknown
/// string to `.caption` rather than throwing, so a future backend value can't
/// crash decoding of the whole recipe.
public enum SourceType: String, Codable, Hashable {
    case caption
    case generated

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceType(rawValue: raw) ?? .caption
    }
}

/// Backend `image_source` (Literal["video_thumbnail", "stock_photo", "none"]).
/// Decodes an unknown string to `.none`.
public enum ImageSource: String, Codable, Hashable {
    case videoThumbnail = "video_thumbnail"
    case stockPhoto = "stock_photo"
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImageSource(rawValue: raw) ?? .none
    }
}
