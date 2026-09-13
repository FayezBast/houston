import SwiftUI

/// How much of the island is showing: the notch-hugging strip, a short alert peek, or the full panel.
enum IslandPresentation: Int, Comparable, Sendable {
    case compact, peek, expanded
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Timing shared by the island and the panel that hosts it. Restrained springs preserve continuity;
/// Reduce Motion updates geometry immediately and keeps content changes gentle.
enum IslandMotion {
    /// The panel waits this long for the collapse spring before it shrinks around the island.
    static let settle: TimeInterval = 0.5

    /// Attention gets a little emphasis without making the camera housing feel elastic.
    static func presentation(_ target: IslandPresentation, moment: IslandMoment? = nil, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch target {
        case .expanded: return .spring(duration: 0.48, bounce: 0.08)
        case .peek: return .spring(duration: 0.42, bounce: moment == .attention ? 0.14 : moment == .start ? 0.04 : 0.08)
        case .compact: return .spring(duration: 0.36, bounce: 0)
        }
    }

    static func content(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0)
    }
}

enum IslandStyle {
    static let cardRadius: CGFloat = 18
    static let pagePadding: CGFloat = 20
    /// The line of detail text under the band while an alert peeks out of the notch.
    static let peekRowHeight: CGFloat = 30
    /// A faint key line separates the open island from dark windows beneath it.
    static let keyLine = Color.white.opacity(0.12)
}

/// The island's outline. On a notched display the top corners flare outward so the black shape reads as part of
/// the camera housing, and the bottom corners grow as the island opens. Without a notch it is a detached pill.
struct IslandShape: InsettableShape {
    var topRadius: CGFloat
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    static func style(for presentation: IslandPresentation, notched: Bool) -> IslandShape {
        switch (notched, presentation) {
        case (true, .compact): IslandShape(topRadius: 0, earRadius: 8, bottomRadius: 14)
        case (true, .peek): IslandShape(topRadius: 0, earRadius: 10, bottomRadius: 22)
        case (true, .expanded): IslandShape(topRadius: 0, earRadius: 12, bottomRadius: 28)
        case (false, .compact): IslandShape(topRadius: 17, earRadius: 0, bottomRadius: 17)
        case (false, .peek): IslandShape(topRadius: 22, earRadius: 0, bottomRadius: 22)
        case (false, .expanded): IslandShape(topRadius: 28, earRadius: 0, bottomRadius: 28)
        }
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, earRadius), bottomRadius) }
        set {
            topRadius = newValue.first.first
            earRadius = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let inner = rect.width - 2 * ear
        let top = ear > 0 ? 0 : max(0, min(topRadius, inner / 2, rect.height / 2))
        let bottom = max(0, min(bottomRadius, inner / 2, rect.height - top))
        let left = rect.minX + ear, right = rect.maxX - ear
        var path = Path()
        path.move(to: CGPoint(x: left + top, y: rect.minY))
        path.addLine(to: CGPoint(x: right - top, y: rect.minY))
        if ear > 0 {
            // The wall curves outward into the menu bar, like the camera housing itself.
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + ear), control: CGPoint(x: right, y: rect.minY))
        } else if top > 0 {
            path.addRelativeArc(center: CGPoint(x: right - top, y: rect.minY + top), radius: top, startAngle: .degrees(-90), delta: .degrees(90))
        }
        path.addLine(to: CGPoint(x: right, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addRelativeArc(center: CGPoint(x: right - bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(0), delta: .degrees(90))
        }
        path.addLine(to: CGPoint(x: left + bottom, y: rect.maxY))
        if bottom > 0 {
            path.addRelativeArc(center: CGPoint(x: left + bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(90), delta: .degrees(90))
        }
        path.addLine(to: CGPoint(x: left, y: rect.minY + max(ear, top)))
        if ear > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        } else if top > 0 {
            path.addRelativeArc(center: CGPoint(x: left + top, y: rect.minY + top), radius: top, startAngle: .degrees(180), delta: .degrees(90))
        }
        path.closeSubpath()
        return path
    }
}
