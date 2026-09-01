//
//  CookClock.swift
//  RecipeApp
//
//  Shared "m:ss" formatting for Cook Mode countdowns (the step timer card and
//  the active-timer badge render the same way). Rounds remaining seconds UP so a
//  freshly started 5:00 timer reads 5:00, then 4:59 a second later — never a
//  momentary 4:59 at the top. Clamped at 0:00 so an overrun shows "0:00", never
//  a negative clock.
//

import Foundation

enum CookClock {
    static func mmss(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
