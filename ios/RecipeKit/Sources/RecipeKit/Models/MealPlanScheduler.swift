//
//  MealPlanScheduler.swift
//  RecipeKit
//
//  Picks which days a Plan on a Budget's dinners land on. Never stacks a dinner
//  on a day that already has one: it walks forward from `start`, skipping days
//  whose dinner slot is taken.
//

import Foundation

public enum MealPlanScheduler {

    /// Stable local-day key ("yyyy-MM-dd"), the same format `MealPlanEntry.dayKey` uses.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The first `count` days at/after `start` (start-of-day) that have no dinner.
    /// `occupiedDinnerDayKeys` are the day keys that already hold a dinner.
    public static func nextOpenDays(
        count: Int,
        from start: Date,
        occupiedDinnerDayKeys: Set<String>,
        calendar: Calendar = .current
    ) -> [Date] {
        guard count > 0 else { return [] }
        var day = calendar.startOfDay(for: start)
        var result: [Date] = []
        // Bounded so a pathological store can't loop forever.
        var guardCount = 0
        while result.count < count, guardCount < 3660 {
            if !occupiedDinnerDayKeys.contains(dayKey(for: day, calendar: calendar)) {
                result.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return result
    }
}
