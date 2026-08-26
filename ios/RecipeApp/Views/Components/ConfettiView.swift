//
//  ConfettiView.swift
//  RecipeApp
//
//  A lightweight, dependency-free confetti burst built on TimelineView + Canvas.
//  No third-party package: particles are plain structs whose position is a pure
//  function of elapsed time (initial velocity + gravity), so the whole thing is
//  ~60 rounded rects redrawn each frame for a short window, then it goes idle.
//
//  Drive it by incrementing `trigger`. Each change spawns a fresh burst from
//  near the top-center of the view, scatters with gravity + rotation, fades out,
//  and then pauses the timeline so it costs nothing at rest. Purely decorative:
//  it never intercepts touches, and callers should simply not fire it when the
//  system Reduce Motion setting is on.
//

import SwiftUI

struct ConfettiView: View {
    /// Increment to fire a new burst. Value is otherwise ignored.
    let trigger: Int
    /// Colors to draw particles from. Callers pass the app palette plus a couple
    /// of bright accents so pieces stay legible against the warm background.
    var colors: [Color] = ConfettiView.defaultPalette

    /// Sage, clay-brown, cream, plus bright golds/corals/teal so the burst reads
    /// as celebratory rather than muddy against the app's warm tones.
    static let defaultPalette: [Color] = [
        Color.accentColor,                          // sage
        Color.secondaryAccent,                      // clay-brown
        Color(red: 0.98, green: 0.96, blue: 0.93),  // cream
        Color(red: 1.00, green: 0.80, blue: 0.25),  // bright gold
        Color(red: 0.96, green: 0.42, blue: 0.35),  // coral
        Color(red: 0.30, green: 0.62, blue: 0.72),  // teal
    ]

    private let burstDuration: TimeInterval = 1.8
    private let particleCount = 140

    @State private var particles: [Particle] = []
    @State private var startAt: Date? = nil

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: startAt == nil)) { timeline in
                Canvas { context, size in
                    guard let startAt else { return }
                    let t = timeline.date.timeIntervalSince(startAt)
                    guard t <= burstDuration else { return }

                    for p in particles {
                        draw(p, elapsed: t, in: size, context: &context)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    // MARK: - Drawing

    private func draw(_ p: Particle, elapsed t: TimeInterval, in size: CGSize, context: inout GraphicsContext) {
        let x = p.startX * size.width + p.vx * t
        let y = p.startY * size.height + p.vy * t + 0.5 * p.gravity * t * t

        // Hold full opacity, then ease out over the tail of the burst.
        let fadeStart = burstDuration * 0.65
        let opacity: Double = t < fadeStart
            ? 1
            : max(0, 1 - (t - fadeStart) / (burstDuration - fadeStart))
        guard opacity > 0 else { return }

        let angle = Angle.radians(p.rotationSpeed * t)
        let rect = CGRect(x: -p.width / 2, y: -p.height / 2, width: p.width, height: p.height)

        context.drawLayer { layer in
            layer.translateBy(x: x, y: y)
            layer.rotate(by: angle)
            layer.opacity = opacity
            layer.fill(
                Path(roundedRect: rect, cornerRadius: 2.5),
                with: .color(p.color)
            )
        }
    }

    // MARK: - Firing

    private func fire() {
        particles = (0..<particleCount).map { _ in Particle.random(from: colors) }
        startAt = Date()

        // Let the burst finish, then pause the timeline so it idles at zero cost.
        let expected = startAt
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((burstDuration + 0.1) * 1_000_000_000))
            if startAt == expected {
                startAt = nil
                particles = []
            }
        }
    }

    // MARK: - Particle

    private struct Particle {
        var startX: CGFloat   // fraction of width  (spawn origin)
        var startY: CGFloat   // fraction of height (spawn origin)
        var vx: CGFloat       // points / sec
        var vy: CGFloat       // points / sec (negative = initial upward kick)
        var gravity: CGFloat  // points / sec^2
        var width: CGFloat
        var height: CGFloat
        var rotationSpeed: Double // radians / sec
        var color: Color

        static func random(from colors: [Color]) -> Particle {
            return Particle(
                // Spawn across the full width and upper band so the burst fills
                // the whole screen rather than fountaining from one point.
                startX: CGFloat.random(in: 0.0...1.0),
                startY: CGFloat.random(in: -0.05...0.25),
                vx: CGFloat.random(in: -320...320),
                vy: CGFloat.random(in: -560 ... -180),
                gravity: CGFloat.random(in: 900...1300),
                width: CGFloat.random(in: 10...20),
                height: CGFloat.random(in: 14...26),
                rotationSpeed: Double.random(in: -6...6),
                color: colors.randomElement() ?? .accentColor
            )
        }
    }
}
