//
//  Recipe.swift
//  RecipeApp
//
//  Swift mirror of the backend Pydantic models in `app/models.py`.
//
//  These are `Codable` and use explicit snake_case `CodingKeys`, so real JSON
//  from the API will decode into them later without any changes — no decoder
//  key-strategy configuration required.
//
//  Optionality matches the Python `Optional[...]` fields exactly so that real
//  data containing nulls decodes cleanly instead of throwing.
//

import Foundation

// MARK: - Recipe

/// Mirror of backend `Recipe` (app/models.py §4).
struct Recipe: Codable, Identifiable, Hashable {
    let recipeId: String
    let canonicalVideoId: String
    let title: String
    let servings: Servings
    let prepTimeMinutes: Double?
    let cookTimeMinutes: Double?
    let totalTimeMinutes: Double?
    let ingredients: [Ingredient]
    let instructions: [Instruction]
    /// Present on the backend and drives future confidence-based UI treatment
    /// (CLAUDE.md §5). Optional here because it is not needed for this pass.
    let confidence: Confidence?
    let sourceType: SourceType
    let imageUrl: String?
    let imageSource: ImageSource

    /// Future-facing nullable field (CLAUDE.md §8). Always null today.
    let transcript: String?

    // NOTE: The backend `Recipe` also carries a freeform `nutrition` dict
    // (always null today). It is intentionally omitted here: `Codable` ignores
    // unknown JSON keys, so decoding stays lossless, and we will add a typed
    // model for it when the nutrition feature actually lands rather than
    // pulling in an `AnyCodable` helper prematurely.

    var id: String { recipeId }

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
struct Servings: Codable, Hashable {
    let amount: Double?
    let unit: String?
}

// MARK: - Ingredient

/// Mirror of backend `Ingredient`. Only `name` is required; the rest optional.
struct Ingredient: Codable, Hashable {
    let quantity: Double?
    let unit: String?
    let name: String
    let notes: String?
}

// MARK: - Instruction

/// Mirror of backend `Instruction`. `stepNumber` is unique per recipe, so it
/// doubles as a stable `Identifiable` id for `ForEach`.
struct Instruction: Codable, Hashable, Identifiable {
    let stepNumber: Int
    let text: String

    var id: Int { stepNumber }

    enum CodingKeys: String, CodingKey {
        case stepNumber = "step_number"
        case text
    }
}

// MARK: - Confidence

/// Mirror of backend `Confidence` (app/models.py §5).
struct Confidence: Codable, Hashable {
    let overall: Double
    let ingredientsComplete: Bool
    let instructionsComplete: Bool
    let missingFields: [String]

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
enum SourceType: String, Codable, Hashable {
    case caption
    case generated

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceType(rawValue: raw) ?? .caption
    }
}

/// Backend `image_source` (Literal["video_thumbnail", "stock_photo", "none"]).
/// Decodes an unknown string to `.none`.
enum ImageSource: String, Codable, Hashable {
    case videoThumbnail = "video_thumbnail"
    case stockPhoto = "stock_photo"
    case none

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImageSource(rawValue: raw) ?? .none
    }
}
