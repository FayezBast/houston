import AppKit
import SwiftUI
import HoustonCore

/// What an island moment announces. Each moment has its own choreography beside the camera, and the ones that
/// need the person also chime. Alerts that are not about an agent arrive as a plain notice.
enum IslandMoment: Equatable, Sendable {
    case start, attention, finish, failure, notice

    /// How long the peek stays out before the island settles back to the compact strip.
    var duration: TimeInterval {
        switch self {
        case .start: 2.6
        case .attention, .failure: 6
        case .finish, .notice: 5
        }
    }

    var cue: IslandSounds.Cue? {
        switch self {
        case .attention: .attention
        case .finish: .finish
        case .failure: .failure
        case .start, .notice: nil
        }
    }
}

/// A transient update shown in the island itself, the way the Dynamic Island presents an update instead of a banner.
struct IslandPeek: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// A few words for the strip beside the camera; the full title and body stay in Recent alerts.
    let headline: String
    let detail: String
    let symbol: String
    let tint: Color
    let tab: PanelTab
    let moment: IslandMoment
    let sessionID: String?
    /// The agent's mark, shown inside the working ring while a session starts.
    let logo: String?

    init(_ alert: HoustonAlert) {
        id = alert.id
        title = alert.title
        detail = alert.body
        sessionID = alert.sessionID
        logo = nil
        let lowercased = alert.title.lowercased()
        if alert.sessionID != nil {
            tab = .agents
            if lowercased.contains("input") { symbol = "hand.raised.fill"; tint = .orange; headline = "Needs input"; moment = .attention }
            else if lowercased.contains("failed") { symbol = "exclamationmark.triangle.fill"; tint = .red; headline = "Turn failed"; moment = .failure }
            else { symbol = "checkmark.circle.fill"; tint = .green; headline = "Response ready"; moment = .finish }
        } else if alert.url?.host()?.hasSuffix("github.com") == true {
            tab = .activity
            moment = .notice
            if lowercased.contains("failed") { symbol = "xmark.circle.fill"; tint = .red }
            else if lowercased.contains("changes") { symbol = "exclamationmark.bubble.fill"; tint = .orange }
            else { symbol = "checkmark.seal.fill"; tint = .green }
            headline = lowercased.contains("approved") ? "Approved" : alert.title
        } else {
            tab = .usage
            moment = .notice
            if lowercased.contains("reset") { symbol = "arrow.clockwise.circle.fill"; tint = .green }
            else { symbol = "gauge.with.dots.needle.67percent"; tint = .orange }
            headline = alert.title.replacingOccurrences(of: " is low", with: " low").replacingOccurrences(of: " has reset", with: " reset")
        }
    }

    /// An agent's own moment: what the session just did, in the words the Agents tab uses.
    init(_ session: AgentSession, moment: IslandMoment) {
        id = UUID()
        title = session.status.title
        detail = session.provider.name + " · " + session.projectName
        tab = .agents
        sessionID = session.id
        logo = session.provider == .codex ? "openai" : "claude"
        self.moment = moment
        switch moment {
        case .start: symbol = "circle.dotted"; tint = .white; headline = "Working"
        case .attention: symbol = "hand.raised.fill"; tint = .orange; headline = "Needs input"
        case .finish: symbol = "checkmark.circle.fill"; tint = .green; headline = "Response ready"
        case .failure: symbol = "exclamationmark.triangle.fill"; tint = .red; headline = "Turn failed"
        case .notice: symbol = "terminal"; tint = .white; headline = session.status.title
        }
    }
}

// MARK: - Sounds

/// The short chimes the island plays for the moments that need the person. They are synthesized on first use, so
/// the app bundles no audio and every Mac hears the same sound, and NSSound plays them through the system output
/// at the system volume like any interface sound.
@MainActor final class IslandSounds {
    enum Cue: String, CaseIterable, Sendable { case attention, finish, failure }

    nonisolated static let sampleRate = 44_100
    private let player: ((Cue) -> Void)?
    private var sounds: [Cue: NSSound] = [:]

    /// A custom player replaces NSSound; tests use one to record cues without playing audio on the development Mac.
    init(player: ((Cue) -> Void)? = nil) { self.player = player }

    func play(_ cue: Cue) {
        if let player { player(cue); return }
        let sound: NSSound
        if let cached = sounds[cue] { sound = cached }
        else {
            guard let made = NSSound(data: Self.wave(for: cue)) else { return }
            made.volume = 0.9
            sounds[cue] = made
            sound = made
        }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// One struck note: partials above a fundamental, each fading at its own rate, like a small bell or a wooden bar.
    private struct Note {
        let start: Double
        let frequency: Double
        let level: Double
        let partials: [(ratio: Double, level: Double, decay: Double)]
    }

    nonisolated private static func notes(for cue: Cue) -> (notes: [Note], length: Double) {
        let bell: [(ratio: Double, level: Double, decay: Double)] = [(1, 1, 0.32), (2, 0.28, 0.18), (3, 0.1, 0.1), (4.2, 0.05, 0.06)]
        let wood: [(ratio: Double, level: Double, decay: Double)] = [(1, 1, 0.09), (3.9, 0.35, 0.03), (9.2, 0.12, 0.012)]
        let soft: [(ratio: Double, level: Double, decay: Double)] = [(1, 1, 0.24), (2, 0.15, 0.12)]
        switch cue {
        case .finish:
            // A rising fifth on a small bell, A5 to E6: bright, resolved, and over in under a second.
            return ([Note(start: 0, frequency: 880, level: 0.8, partials: bell),
                     Note(start: 0.13, frequency: 1318.5, level: 1, partials: bell)], 0.9)
        case .attention:
            // Two wooden taps on C5, like a knock on a door frame: polite, and unmistakably a request.
            return ([Note(start: 0, frequency: 523.25, level: 1, partials: wood),
                     Note(start: 0.15, frequency: 523.25, level: 0.85, partials: wood)], 0.5)
        case .failure:
            // A falling minor third, C5 to A4, on a soft tone: something went wrong, without alarm.
            return ([Note(start: 0, frequency: 523.25, level: 1, partials: soft),
                     Note(start: 0.17, frequency: 440, level: 0.9, partials: soft)], 0.7)
        }
    }

    /// Mono samples in -1…1, peaking well below full scale and fading out at the end so nothing clicks.
    nonisolated static func samples(for cue: Cue) -> [Float] {
        let rate = Double(sampleRate)
        let (notes, seconds) = notes(for: cue)
        let length = Int(rate * seconds)
        var samples = [Double](repeating: 0, count: length)
        for note in notes {
            let offset = Int(note.start * rate)
            for partial in note.partials {
                let frequency = note.frequency * partial.ratio
                for index in offset..<length {
                    let t = Double(index - offset) / rate
                    let envelope = min(1, t / 0.004) * exp(-t / partial.decay)
                    samples[index] += note.level * partial.level * envelope * sin(2 * .pi * frequency * t)
                }
            }
        }
        let peak = samples.map(abs).max() ?? 0
        let gain = peak > 0 ? 0.42 / peak : 0
        let fade = Double(Int(rate * 0.05))
        return samples.enumerated().map { index, value in
            Float(value * gain * min(1, Double(length - index) / fade))
        }
    }

    nonisolated static func wave(for cue: Cue) -> Data { wav(samples(for: cue)) }

    /// A 16-bit mono WAV container around the samples; NSSound reads it like a file.
    nonisolated static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples { append(Int16((max(-1, min(1, sample)) * 32_767).rounded())) }
        return data
    }
}

// MARK: - Continuous indicators

/// Dots orbiting the trailing slot while an agent works. The turn is a Core Animation transaction that the render
/// server runs on its own, so the island spends no main-thread time while it moves; a repeating SwiftUI or symbol
/// effect would redraw every frame instead. Without motion the dots hold still at an even brightness.
struct WorkingOrbit: NSViewRepresentable {
    var tint: NSColor = .white
    var size: CGFloat = 16
    var turning = true

    func makeNSView(context: Context) -> OrbitView { OrbitView() }
    func updateNSView(_ view: OrbitView, context: Context) { view.configure(tint: tint, size: size, turning: turning) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OrbitView, context: Context) -> CGSize? { CGSize(width: size, height: size) }

    final class OrbitView: NSView {
        private let ring = CALayer()
        private let dots = (0..<8).map { _ in CAShapeLayer() }
        private var turning = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for dot in dots { ring.addSublayer(dot) }
            layer?.addSublayer(ring)
            setAccessibilityElement(false)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("OrbitView is created in code") }

        func configure(tint: NSColor, size: CGFloat, turning: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var color = tint.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { color = tint.cgColor }
            // Three-point dots read at both sizes and leave room for a logo inside the larger ring.
            let diameter: CGFloat = size >= 20 ? 3 : max(2, (size * 0.18).rounded())
            let radius = size / 2 - diameter / 2 - 0.5
            ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            for (index, dot) in dots.enumerated() {
                // Clockwise from the top; the ring then turns the other way, so the lit head leads and the tail trails.
                let angle = CGFloat(index) / CGFloat(dots.count) * 2 * .pi
                dot.path = CGPath(ellipseIn: CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter), transform: nil)
                dot.fillColor = color
                dot.position = CGPoint(x: size / 2 + radius * sin(angle), y: size / 2 + radius * cos(angle))
                // A still ring is even, like the dotted circle symbol.
                dot.opacity = turning ? 1 - 0.83 * Float(index) / Float(dots.count - 1) : 0.8
            }
            CATransaction.commit()
            self.turning = turning
            restart()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restart()
        }

        private func restart() {
            ring.removeAnimation(forKey: "turn")
            guard turning, window != nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * CGFloat.pi
            turn.duration = 2.4
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        }
    }
}

/// A symbol that breathes while an agent waits for you. The pulse is a Core Animation opacity cycle on the image
/// view's layer, so it also costs no main-thread time; without motion the symbol simply holds.
struct BreathingSymbol: NSViewRepresentable {
    var name: String
    var tint: NSColor
    var pointSize: CGFloat
    var breathing = true

    func makeNSView(context: Context) -> BreathingView { BreathingView() }
    func updateNSView(_ view: BreathingView, context: Context) { view.configure(name: name, tint: tint, pointSize: pointSize, breathing: breathing) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreathingView, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return size.width > 0 ? size : nil
    }

    final class BreathingView: NSImageView {
        private var breathing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            imageScaling = .scaleNone
            isEditable = false
            setAccessibilityElement(false)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("BreathingView is created in code") }

        func configure(name: String, tint: NSColor, pointSize: CGFloat, breathing: Bool) {
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            contentTintColor = tint
            self.breathing = breathing
            restart()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restart()
        }

        private func restart() {
            layer?.removeAnimation(forKey: "breathe")
            guard breathing, window != nil, let layer else { return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.45
            breathe.duration = 1.2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(breathe, forKey: "breathe")
        }
    }
}

// MARK: - Moment choreography

/// The symbol beside the camera during a moment, with the choreography Apple gives its own island updates: a
/// starting agent settles in inside its working ring, a finished one pops with a bloom of light, one that needs
/// you waves with a double knock of light, and a failed turn shakes its head. Reduce Motion keeps the symbol still.
struct MomentBadge: View {
    let peek: IslandPeek
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0

    private struct Choreography {
        var scale: CGFloat = 1
        var shake: CGFloat = 0
    }

    var body: some View {
        let (entrance, overshoot, jolt): (CGFloat, CGFloat, CGFloat) = switch peek.moment {
        case .start: (0.6, 1.08, 0)
        case .attention: (0.7, 1.12, 0)
        case .finish: (0.4, 1.18, 0)
        case .failure: (0.85, 1, 4)
        case .notice: (0.7, 1.08, 0)
        }
        ZStack {
            if !reduceMotion, peek.moment == .finish || peek.moment == .attention {
                Bloom(tint: peek.tint, knocks: peek.moment == .attention ? 2 : 1, beat: beat)
            }
            glyph
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: Choreography(), trigger: beat) { content, value in
            content.scaleEffect(value.scale).offset(x: value.shake)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(entrance)
                SpringKeyframe(overshoot, duration: 0.18, spring: Spring(duration: 0.18, bounce: 0))
                SpringKeyframe(1, duration: 0.5, spring: Spring(duration: 0.5, bounce: 0.45))
            }
            KeyframeTrack(\.shake) {
                CubicKeyframe(-jolt, duration: 0.06)
                CubicKeyframe(jolt, duration: 0.07)
                CubicKeyframe(-jolt * 0.6, duration: 0.07)
                CubicKeyframe(jolt * 0.35, duration: 0.07)
                CubicKeyframe(0, duration: 0.08)
            }
        }
        .onAppear { if !reduceMotion { beat += 1 } }
        .onChange(of: peek.id) { _, _ in if !reduceMotion { beat += 1 } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch peek.moment {
        case .start:
            ZStack {
                WorkingOrbit(tint: .white, size: size, turning: !reduceMotion)
                if let logo = peek.logo { BrandLogo(name: logo, size: size * 0.42, color: .white.opacity(0.95)) }
            }
        case .attention:
            symbol.modifier(Wave(beat: beat))
        case .notice:
            symbol.symbolEffect(.bounce, value: beat)
        case .finish, .failure:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: peek.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(peek.tint)
    }
}

/// A raised hand waves on macOS 15 and later; earlier systems bounce it.
private struct Wave: ViewModifier {
    let beat: Int
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.symbolEffect(.wiggle.byLayer, value: beat) }
        else { content.symbolEffect(.bounce, value: beat) }
    }
}

/// A soft knock of light behind a symbol that just arrived: it swells and fades once, or twice for a request.
private struct Bloom: View {
    let tint: Color
    let knocks: Int
    let beat: Int

    private struct Glow {
        var scale: CGFloat = 0.6
        var opacity: Double = 0
    }

    var body: some View {
        let dip = knocks > 1 ? 0.1 : 0.35
        let again = knocks > 1 ? 0.5 : 0.2
        Circle().fill(tint).blur(radius: 3)
            .keyframeAnimator(initialValue: Glow(), trigger: beat) { content, glow in
                content.scaleEffect(glow.scale).opacity(glow.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.2, duration: 0.2)
                    CubicKeyframe(1.45, duration: 0.6)
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(0.55, duration: 0.06)
                    CubicKeyframe(dip, duration: 0.12)
                    CubicKeyframe(again, duration: 0.06)
                    CubicKeyframe(0, duration: 0.56)
                }
            }
            .allowsHitTesting(false)
    }
}
