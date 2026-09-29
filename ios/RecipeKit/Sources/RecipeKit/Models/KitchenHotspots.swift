//
//  KitchenHotspots.swift
//  RecipeKit
//
//  The tap areas of the interactive kitchen picture on the Appliances screen.
//  Every rect is NORMALIZED (0–1 of the image's width/height), so the same table
//  scales to any device and any rendered image size.
//
//  >>> PLACEHOLDER RECTS <<< — a 4×2 grid until the `kitchen_scene` art lands.
//  When it does, edit ONLY `table` below (and `imageAspectRatio` if the art isn't
//  4:3); nothing else needs to change.
//

import CoreGraphics
import Foundation

public struct NormalizedRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    /// Inclusive of the top/left edge, exclusive of the bottom/right edge, so two
    /// touching rects never both claim a point on their shared edge.
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    /// This rect in a view of `size` (points).
    public func frame(in size: CGSize) -> CGRect {
        let w: Double = Double(size.width)
        let h: Double = Double(size.height)
        let originX: Double = self.x * w
        let originY: Double = self.y * h
        let rectW: Double = self.width * w
        let rectH: Double = self.height * h
        return CGRect(x: originX, y: originY, width: rectW, height: rectH)
    }
}

public enum KitchenHotspots {
    /// width ÷ height of the `kitchen_scene` picture (and of its placeholder).
    public static let imageAspectRatio: Double = 4.0 / 3.0

    public struct Hotspot: Sendable {
        public let appliance: Appliance
        public let rect: NormalizedRect
        init(_ appliance: Appliance, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
            self.appliance = appliance
            self.rect = NormalizedRect(x: x, y: y, width: width, height: height)
        }
    }

    /// THE table. One entry per appliance, in display order: (appliance, x, y, w, h).
    public static let table: [Hotspot] = [
        Hotspot(.stovetop,   0.04, 0.08, 0.22, 0.38),
        Hotspot(.oven,       0.28, 0.08, 0.22, 0.38),
        Hotspot(.microwave,  0.52, 0.08, 0.22, 0.38),
        Hotspot(.airFryer,   0.76, 0.08, 0.20, 0.38),
        Hotspot(.slowCooker, 0.04, 0.54, 0.22, 0.38),
        Hotspot(.riceCooker, 0.28, 0.54, 0.22, 0.38),
        Hotspot(.blender,    0.52, 0.54, 0.22, 0.38),
        Hotspot(.kettle,     0.76, 0.54, 0.20, 0.38),
    ]

    public static func rect(for appliance: Appliance) -> NormalizedRect? {
        table.first { $0.appliance == appliance }?.rect
    }

    /// The appliance under a normalized point. Where rects overlap, the smallest
    /// (most specific) one wins; a point outside every rect returns nil.
    public static func appliance(atNormalized x: Double, _ y: Double) -> Appliance? {
        table
            .filter { $0.rect.contains(x: x, y: y) }
            .min { $0.rect.area < $1.rect.area }?
            .appliance
    }

    /// The appliance under a point in a rendered image of `size` (points).
    public static func appliance(at point: CGPoint, in size: CGSize) -> Appliance? {
        guard size.width > 0, size.height > 0 else { return nil }
        return appliance(atNormalized: Double(point.x / size.width), Double(point.y / size.height))
    }
}
