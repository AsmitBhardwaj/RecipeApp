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
    public let sourceUrl: String?
    public let sourcePlatform: String?
    public let sourceCreator: String?

    /// Future-facing nullable field (CLAUDE.md §8). Always null today.
    public let transcript: String?

    /// Rough estimated (or creator-stated) nutrition for the recipe, or nil when
    /// the source lacked enough usable ingredient quantities to estimate. Lives
    /// on the shared cached recipe (computed once per recipe, not per user).
    /// Optional + a nil default in the init, so recipes cached before nutrition
    /// shipped decode as nil and existing construction sites are unaffected.
    public let nutrition: Nutrition?

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
        transcript: String?,
        nutrition: Nutrition? = nil,
        sourceUrl: String? = nil,
        sourcePlatform: String? = nil,
        sourceCreator: String? = nil
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
        self.sourceUrl = sourceUrl
        self.sourcePlatform = sourcePlatform
        self.sourceCreator = sourceCreator
        self.transcript = transcript
        self.nutrition = nutrition
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
        case sourceUrl = "source_url"
        case sourcePlatform = "source_platform"
        case sourceCreator = "source_creator"
        case transcript
        case nutrition
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
    /// Per-step cooking duration in seconds when the backend extracted one
    /// ("bake for 20 minutes" -> 1200); nil when absent/ambiguous or for recipes
    /// saved before Cook Mode shipped. The synthesized decoder treats a missing
    /// key as nil, so older cached JSON round-trips unchanged. When nil, Cook Mode
    /// falls back to `StepDurationParser` on `text` (see `effectiveDurationSeconds`).
    public let durationSeconds: Int?

    public var id: Int { stepNumber }

    public init(stepNumber: Int, text: String, durationSeconds: Int? = nil) {
        self.stepNumber = stepNumber
        self.text = text
        self.durationSeconds = durationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case stepNumber = "step_number"
        case text
        case durationSeconds = "duration_seconds"
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

// MARK: - Nutrition

/// Mirror of backend `Nutrition` (app/models.py / NUTRIENT_SCOPE.md). Rough,
/// per-recipe nutrition produced in the extraction call. Every macro is optional
/// so a partial estimate decodes cleanly; `basis` and `source` are the honesty
/// markers the UI reads to label what it's showing.
public struct Nutrition: Codable, Hashable {
    public let calories: Double?
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    /// Whether the numbers are per serving or whole-recipe totals.
    public let basis: Basis
    /// Whether the numbers were estimated from ingredients or stated by the source.
    public let source: Source

    public init(
        calories: Double?,
        proteinG: Double?,
        carbsG: Double?,
        fatG: Double?,
        basis: Basis,
        source: Source
    ) {
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.basis = basis
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case basis
        case source
    }

    /// Backend `basis` (Literal["per_serving", "per_recipe"]). An unknown value
    /// decodes to `.perRecipe` — the more conservative, less-specific claim.
    public enum Basis: String, Codable, Hashable {
        case perServing = "per_serving"
        case perRecipe = "per_recipe"

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Basis(rawValue: raw) ?? .perRecipe
        }
    }

    /// Backend `source` (Literal["estimated", "creator_stated"]). An unknown
    /// value decodes to `.estimated`.
    public enum Source: String, Codable, Hashable {
        case estimated
        case creatorStated = "creator_stated"

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .estimated
        }
    }
}

// MARK: - Enums (decode defensively)

/// Backend `source_type` (Literal["caption", "generated", "structured",
/// "article"]). Decodes an unknown string to `.caption` rather than throwing,
/// so a future backend value can't crash decoding of the whole recipe.
///
/// - `caption`    : extracted from a video caption.
/// - `generated`  : AI-generated (no reliable source, or method-only fallback).
/// - `structured` : parsed from a page's schema.org JSON-LD — ground truth.
/// - `article`    : LLM-extracted from a blog article's body text.
public enum SourceType: String, Codable, Hashable {
    case caption
    case generated
    case structured
    case article

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceType(rawValue: raw) ?? .caption
    }
}

/// Backend `image_source` (Literal["video_thumbnail", "stock_photo",
/// "web_image", "none"]). Decodes an unknown string to `.none`.
public enum ImageSource: String, Codable, Hashable {
    case videoThumbnail = "video_thumbnail"
    case stockPhoto = "stock_photo"
    /// Image taken from the recipe web page itself (JSON-LD image / og:image).
    case webImage = "web_image"
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImageSource(rawValue: raw) ?? .none
    }
}
