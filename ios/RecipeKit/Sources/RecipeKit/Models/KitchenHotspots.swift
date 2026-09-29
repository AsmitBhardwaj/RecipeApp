//
//  KitchenHotspots.swift
//  RecipeKit
//
//  The tap areas of the interactive kitchen picture on the Appliances screen.
//  Every rect is NORMALIZED (0–1 of the image's width/height), so the same table
//  scales to any device and any rendered image size.
//
//  Rects were measured on the 1200×1490 `kitchen_scene` art. If the art changes,
//  edit ONLY `table` below (and `imageAspectRatio` if the dimensions change).
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
    /// width ÷ height of the `kitchen_scene` picture (1200×1490).
    public static let imageAspectRatio: Double = 1200.0 / 1490.0

    public struct Hotspot: Sendable {
        public let appliance: Appliance
        public let rect: NormalizedRect
        /// Show the selected-state name above the rect instead of below it, where
        /// the label below would cover a neighbouring appliance.
        public let labelAbove: Bool
        init(_ appliance: Appliance, _ x: Double, _ y: Double, _ width: Double, _ height: Double, labelAbove: Bool = false) {
            self.appliance = appliance
            self.labelAbove = labelAbove
            self.rect = NormalizedRect(x: x, y: y, width: width, height: height)
        }
    }

    /// THE table. One entry per appliance, in display order: (appliance, x, y, w, h).
    public static let table: [Hotspot] = [
        Hotspot(.blender,    0.452, 0.148, 0.106, 0.149),
        Hotspot(.microwave,  0.017, 0.436, 0.225, 0.120),
        Hotspot(.kettle,     0.258, 0.434, 0.114, 0.122, labelAbove: true),
        Hotspot(.stovetop,   0.380, 0.475, 0.274, 0.097, labelAbove: true),
        Hotspot(.riceCooker, 0.660, 0.442, 0.163, 0.116, labelAbove: true),
        Hotspot(.airFryer,   0.833, 0.420, 0.150, 0.138),
        Hotspot(.oven,       0.340, 0.592, 0.320, 0.236),
        Hotspot(.slowCooker, 0.075, 0.622, 0.207, 0.126),
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
