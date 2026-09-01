//
//  StepDurationParser.swift
//  RecipeKit
//
//  Cook Mode's client-side safety net: derive a per-step cooking duration from
//  the step TEXT when the backend didn't supply a structured `duration_seconds`.
//  This is what makes Cook Mode timers work for the whole existing install base
//  (recipes saved before Cook Mode) and for web/JSON-LD recipes, whose steps
//  never carry a structured duration.
//
//  It is a FALLBACK, not the primary path: `Instruction.effectiveDurationSeconds`
//  prefers the structured field and only calls this when it's nil.
//
//  Stage 1 rules (deliberately conservative — revisit if they misfire in practice):
//    • First match only. "chop for 5 min, then rest 10 min" -> 5 min. The step's
//      timer represents the step's first timed action.
//    • Ranges take the LOWER bound. "2–3 min" -> 2 min (firing early beats late).
//    • A compound "1 hour 30 minutes" (descending adjacent units) is summed into
//      one duration; a second, same-or-larger unit is treated as a separate
//      phrase and ignored (first-match rule).
//    • Temperatures, pan sizes, quantities etc. never match — a time UNIT is
//      required ("350°F", "9x13", "2 cups" -> nil).
//

import Foundation

public enum StepDurationParser {

    /// Seconds for the first cooking duration expressed in `text`, or nil if none.
    public static func seconds(from text: String) -> Int? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        func group(_ name: String) -> String? {
            let r = match.range(withName: name)
            guard r.location != NSNotFound, let sr = Range(r, in: text) else { return nil }
            return String(text[sr])
        }

        // Primary quantity: lower bound of a range is just the first number (n2 is
        // captured for clarity but intentionally unused).
        guard let n1 = group("n1").flatMap(Double.init),
              let u1 = group("u1").flatMap(unitMultiplier) else { return nil }

        var total = n1 * Double(u1)

        // Compound trailing unit (e.g. the "30 minutes" of "1 hour 30 minutes"):
        // only sum it when it's strictly SMALLER than the leading unit, otherwise
        // it's a separate phrase and the first-match rule drops it.
        if let n2v = group("cn").flatMap(Double.init),
           let u2 = group("cu").flatMap(unitMultiplier),
           u2 < u1 {
            total += n2v * Double(u2)
        }

        let seconds = Int(total.rounded())
        return seconds > 0 ? seconds : nil
    }

    // MARK: - Internals

    /// seconds-per-unit; nil for anything that isn't a time unit.
    private static func unitMultiplier(_ raw: String) -> Int? {
        switch raw.lowercased() {
        case "h", "hr", "hrs", "hour", "hours": return 3600
        case "m", "min", "mins", "minute", "minutes": return 60
        case "s", "sec", "secs", "second", "seconds": return 1
        default: return nil
        }
    }

    /// Number (or range low-high) + time unit, with an optional adjacent smaller
    /// unit for compound durations. Longest unit spellings first so e.g. "hours"
    /// wins over "h". Case-insensitive.
    private static let regex: NSRegularExpression = {
        let unit = "(?:hours?|hrs?|hr|h|minutes?|mins?|min|m|seconds?|secs?|sec|s)"
        let smaller = "(?:minutes?|mins?|min|m|seconds?|secs?|sec|s)"
        let pattern = """
        (?<n1>\\d+(?:\\.\\d+)?)\\s*(?:(?:[-–—]|to)\\s*(?<n2>\\d+(?:\\.\\d+)?))?\\s*\
        (?<u1>\(unit))\\b\
        (?:\\s*(?:and\\s+)?(?<cn>\\d+(?:\\.\\d+)?)\\s*(?<cu>\(smaller))\\b)?
        """
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
}

public extension Instruction {
    /// The duration Cook Mode uses for this step: the structured backend value
    /// when present, otherwise regex-derived from the step text, otherwise nil
    /// (no timer card renders for the step).
    var effectiveDurationSeconds: Int? {
        durationSeconds ?? StepDurationParser.seconds(from: text)
    }
}
