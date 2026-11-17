import AppKit
import DremCore
import SwiftUI

enum IslandPalette {
    private static let projects: [NSColor] = [
        NSColor(srgbRed: 0.46, green: 0.84, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.68, blue: 0.43, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.62, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.49, green: 0.91, blue: 0.76, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.57, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.46, green: 0.67, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.86, blue: 0.82, alpha: 1)
    ]

    static func color(_ kind: AgentKind) -> Color { Color(nsColor: nsColor(kind)) }
    static func nsColor(_ kind: AgentKind) -> NSColor { kind == .codex ? projects[0] : projects[1] }
    static func project(_ token: Int) -> NSColor {
        // Seven fixed colours made unrelated folders collide often. Preserve a
        // deterministic 24-bit folder token and spread all of it over a gentle
        // hue plus small saturation/brightness variations. Every channel stays
        // bounded for readable dark-island contrast.
        let value = UInt32(truncatingIfNeeded: token) & 0x00FF_FFFF
        let hue = CGFloat(value & 0xFFFF) / 65_536
        let saturation = 0.48 + CGFloat((value >> 16) & 0x0F) / 15 * 0.16
        let brightness = 0.90 + CGFloat((value >> 20) & 0x0F) / 15 * 0.08
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
    static func color(_ row: IslandRow) -> Color { Color(nsColor: project(row.colorIndex)) }
}

enum IslandBlobSilhouette: Int, CaseIterable, Hashable {
    case pebble, softBox, capsule, droplet, bean, cloud, gem
}

struct IslandBlobIdentity: Equatable {
    let seed: UInt64
    let colorIndex: Int
    let silhouette: IslandBlobSilhouette
    let eyeSpacing: CGFloat
    let eyeHeight: CGFloat
    let eyeTilt: CGFloat

    init(seed: UInt64) {
        self.seed = seed
        // Mix once before taking traits so even adjacent deterministic seeds
        // do not share a face merely because their upper bits are identical.
        var traits = seed &+ 0x9E37_79B9_7F4A_7C15
        traits = (traits ^ (traits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        traits = (traits ^ (traits >> 27)) &* 0x94D0_49BB_1331_11EB
        traits ^= traits >> 31
        // Keep 24 mixed bits instead of reducing every folder to one of seven
        // buckets. IslandPalette maps the token to a stable pastel colour.
        colorIndex = Int((traits >> 32) & 0x00FF_FFFF)
        silhouette = IslandBlobSilhouette.allCases[Int(traits % UInt64(IslandBlobSilhouette.allCases.count))]
        eyeSpacing = 18 + CGFloat((traits >> 8) % 7)
        eyeHeight = 15 + CGFloat((traits >> 15) % 5)
        eyeTilt = CGFloat(Int((traits >> 22) % 7) - 3) * 0.025
    }
}

enum IslandBlobGeometry {
    static func path(_ silhouette: IslandBlobSilhouette) -> CGPath {
        let path = CGMutablePath()
        switch silhouette {
        case .pebble:
            path.move(to: CGPoint(x: 50, y: 9))
            path.addCurve(to: CGPoint(x: 88, y: 48), control1: CGPoint(x: 75, y: 7), control2: CGPoint(x: 89, y: 24))
            path.addCurve(to: CGPoint(x: 50, y: 91), control1: CGPoint(x: 89, y: 76), control2: CGPoint(x: 75, y: 92))
            path.addCurve(to: CGPoint(x: 11, y: 52), control1: CGPoint(x: 24, y: 92), control2: CGPoint(x: 9, y: 78))
            path.addCurve(to: CGPoint(x: 50, y: 9), control1: CGPoint(x: 9, y: 25), control2: CGPoint(x: 25, y: 11))
        case .softBox:
            path.move(to: CGPoint(x: 28, y: 10))
            path.addCurve(to: CGPoint(x: 82, y: 17), control1: CGPoint(x: 49, y: 6), control2: CGPoint(x: 71, y: 9))
            path.addCurve(to: CGPoint(x: 90, y: 71), control1: CGPoint(x: 91, y: 31), control2: CGPoint(x: 92, y: 58))
            path.addCurve(to: CGPoint(x: 69, y: 90), control1: CGPoint(x: 85, y: 86), control2: CGPoint(x: 78, y: 89))
            path.addCurve(to: CGPoint(x: 17, y: 82), control1: CGPoint(x: 47, y: 94), control2: CGPoint(x: 26, y: 90))
            path.addCurve(to: CGPoint(x: 10, y: 31), control1: CGPoint(x: 8, y: 69), control2: CGPoint(x: 7, y: 45))
            path.addCurve(to: CGPoint(x: 28, y: 10), control1: CGPoint(x: 14, y: 18), control2: CGPoint(x: 20, y: 12))
        case .capsule:
            path.addRoundedRect(in: CGRect(x: 8, y: 22, width: 84, height: 58), cornerWidth: 29, cornerHeight: 29)
        case .droplet:
            path.move(to: CGPoint(x: 50, y: 5))
            path.addCurve(to: CGPoint(x: 87, y: 61), control1: CGPoint(x: 62, y: 24), control2: CGPoint(x: 84, y: 39))
            path.addCurve(to: CGPoint(x: 50, y: 92), control1: CGPoint(x: 88, y: 82), control2: CGPoint(x: 70, y: 92))
            path.addCurve(to: CGPoint(x: 13, y: 61), control1: CGPoint(x: 29, y: 92), control2: CGPoint(x: 12, y: 82))
            path.addCurve(to: CGPoint(x: 50, y: 5), control1: CGPoint(x: 15, y: 40), control2: CGPoint(x: 38, y: 24))
        case .bean:
            path.move(to: CGPoint(x: 39, y: 8))
            path.addCurve(to: CGPoint(x: 88, y: 39), control1: CGPoint(x: 64, y: 5), control2: CGPoint(x: 84, y: 17))
            path.addCurve(to: CGPoint(x: 67, y: 89), control1: CGPoint(x: 94, y: 64), control2: CGPoint(x: 86, y: 83))
            path.addCurve(to: CGPoint(x: 17, y: 77), control1: CGPoint(x: 45, y: 96), control2: CGPoint(x: 23, y: 90))
            path.addCurve(to: CGPoint(x: 39, y: 8), control1: CGPoint(x: 5, y: 58), control2: CGPoint(x: 12, y: 15))
        case .cloud:
            path.move(to: CGPoint(x: 24, y: 18))
            path.addCurve(to: CGPoint(x: 49, y: 12), control1: CGPoint(x: 33, y: 7), control2: CGPoint(x: 42, y: 8))
            path.addCurve(to: CGPoint(x: 73, y: 19), control1: CGPoint(x: 57, y: 5), control2: CGPoint(x: 69, y: 8))
            path.addCurve(to: CGPoint(x: 89, y: 43), control1: CGPoint(x: 87, y: 22), control2: CGPoint(x: 91, y: 31))
            path.addCurve(to: CGPoint(x: 81, y: 72), control1: CGPoint(x: 96, y: 55), control2: CGPoint(x: 91, y: 68))
            path.addCurve(to: CGPoint(x: 53, y: 89), control1: CGPoint(x: 75, y: 86), control2: CGPoint(x: 64, y: 89))
            path.addCurve(to: CGPoint(x: 23, y: 82), control1: CGPoint(x: 41, y: 96), control2: CGPoint(x: 29, y: 90))
            path.addCurve(to: CGPoint(x: 10, y: 56), control1: CGPoint(x: 10, y: 77), control2: CGPoint(x: 7, y: 66))
            path.addCurve(to: CGPoint(x: 24, y: 18), control1: CGPoint(x: 5, y: 42), control2: CGPoint(x: 12, y: 27))
        case .gem:
            path.move(to: CGPoint(x: 50, y: 7))
            path.addCurve(to: CGPoint(x: 88, y: 31), control1: CGPoint(x: 62, y: 8), control2: CGPoint(x: 80, y: 19))
            path.addCurve(to: CGPoint(x: 82, y: 74), control1: CGPoint(x: 93, y: 46), control2: CGPoint(x: 90, y: 65))
            path.addCurve(to: CGPoint(x: 48, y: 92), control1: CGPoint(x: 69, y: 86), control2: CGPoint(x: 59, y: 91))
            path.addCurve(to: CGPoint(x: 13, y: 70), control1: CGPoint(x: 32, y: 91), control2: CGPoint(x: 21, y: 82))
            path.addCurve(to: CGPoint(x: 15, y: 29), control1: CGPoint(x: 7, y: 56), control2: CGPoint(x: 9, y: 40))
            path.addCurve(to: CGPoint(x: 50, y: 7), control1: CGPoint(x: 25, y: 17), control2: CGPoint(x: 39, y: 8))
        }
        path.closeSubpath()
        return path
    }
}

/// Only the featured creature's small layer tree runs continuously. No display
/// timer, transcript polling or frame-by-frame SwiftUI publication is involved.
struct IslandRobot: NSViewRepresentable {
    let kind: AgentKind
    var action: AgentActivityDetail.Action = .working
    var pointer: CGFloat = 0
    var animated = true
    var celebrating = false
    var colorIndex: Int? = nil
    var avatarSeed: UInt64? = nil
    var pointerY: CGFloat = 0
    var reaction = 0
    var needsAttention = false

    func makeNSView(context: Context) -> IslandRobotView { IslandRobotView() }
    func updateNSView(_ view: IslandRobotView, context: Context) {
        view.configure(kind: kind, action: action, pointer: pointer,
            animated: animated, celebrating: celebrating, colorIndex: colorIndex,
            avatarSeed: avatarSeed, pointerY: pointerY, reaction: reaction,
            needsAttention: needsAttention)
    }
    static func dismantleNSView(_ view: IslandRobotView, coordinator: ()) { view.stopMotion() }
}

final class IslandRobotView: NSView {
    private let scene = CALayer()
    private let floating = CALayer()
    private let bodyPose = CALayer()
    private let body = CAShapeLayer()
    private let face = CALayer()
    private let eyes = CALayer()
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private var currentIdentity = IslandBlobIdentity(seed: 0xC0DE_5EED)
    private var configuredKind: AgentKind?
    private var motionEnabled = false
    private var lastPointer: CGFloat = .nan
    private var lastPointerY: CGFloat = .nan
    private var lastAction: AgentActivityDetail.Action?
    private var lastCelebrating = false
    private var lastColorIndex: Int?
    private var lastAvatarSeed: UInt64?
    private var lastReaction = 0
    private var lastAttention = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        wantsLayer = true
        guard let root = layer else { return }
        scene.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.addSublayer(scene)
        floating.frame = scene.bounds
        scene.addSublayer(floating)
        bodyPose.frame = floating.bounds
        floating.addSublayer(bodyPose)

        body.path = IslandBlobGeometry.path(.pebble)
        body.fillColor = IslandPalette.nsColor(.codex).cgColor
        body.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
        body.lineWidth = 1.5
        body.lineJoin = .round
        bodyPose.addSublayer(body)

        face.frame = bodyPose.bounds
        bodyPose.addSublayer(face)
        eyes.frame = face.bounds
        face.addSublayer(eyes)
        for eye in [leftEye, rightEye] {
            eye.bounds = CGRect(x: 0, y: 0, width: 12, height: 22)
            eye.fillColor = NSColor(white: 0.035, alpha: 0.88).cgColor
            eyes.addSublayer(eye)
        }
        applyIdentity(IslandBlobIdentity(seed: fallbackSeed(.codex)))
        applyExpression(action: .working, celebrating: false, needsAttention: false, animated: false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = min(bounds.width / 100, bounds.height / 100)
        scene.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func configure(kind: AgentKind, action: AgentActivityDetail.Action, pointer: CGFloat,
                   animated: Bool, celebrating: Bool, colorIndex: Int? = nil,
                   avatarSeed: UInt64? = nil, pointerY: CGFloat = 0,
                   reaction: Int = 0, needsAttention: Bool = false) {
        let seed = avatarSeed ?? fallbackSeed(kind)
        let identityChanged = lastAvatarSeed != seed
        if identityChanged {
            applyIdentity(IslandBlobIdentity(seed: seed))
            lastAvatarSeed = seed
        }

        let attentionChanged = lastAttention != needsAttention
        let celebrationChanged = lastCelebrating != celebrating
        let actionChanged = lastAction != action
        let presentationChanged = configuredKind != kind || lastColorIndex != colorIndex
        if presentationChanged || celebrationChanged || attentionChanged {
            updateColor(kind: kind, colorIndex: colorIndex, celebrating: celebrating,
                needsAttention: needsAttention, animated: animated)
            configuredKind = kind
            lastColorIndex = colorIndex
        }
        if identityChanged || actionChanged || celebrationChanged || attentionChanged {
            applyExpression(action: action, celebrating: celebrating,
                needsAttention: needsAttention, animated: animated)
        }

        let targetX = animated ? pointer : 0
        let targetY = animated ? pointerY : 0
        if lastPointer != targetX || lastPointerY != targetY {
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? 0.16 : 0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            face.transform = CATransform3DMakeTranslation(targetX * 4.5, targetY * 3.2 - abs(targetX) * 0.7, 0)
            CATransaction.commit()
            lastPointer = targetX
            lastPointerY = targetY
        }

        let reactionChanged = lastReaction != reaction
        let restartMotion = motionEnabled != animated || actionChanged || celebrationChanged || attentionChanged
        lastReaction = reaction
        lastAction = action
        lastCelebrating = celebrating
        lastAttention = needsAttention

        if restartMotion {
            stopMotion()
            motionEnabled = animated
            if animated { startMotion(kind: kind, action: action, needsAttention: needsAttention) }
        }
        if animated && identityChanged {
            let settle = CAKeyframeAnimation(keyPath: "transform.scale")
            settle.values = [0.92, 1.04, 1]
            settle.keyTimes = [0, 0.58, 1]
            settle.duration = 0.28
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bodyPose.add(settle, forKey: "identity")
        }
        if animated && (reactionChanged || celebrationChanged || (attentionChanged && needsAttention)) {
            playReaction(celebrating: celebrating, needsAttention: needsAttention)
        }
    }

    private func applyIdentity(_ identity: IslandBlobIdentity) {
        currentIdentity = identity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = IslandBlobGeometry.path(identity.silhouette)
        let leftX = 50 - identity.eyeSpacing / 2
        let rightX = 50 + identity.eyeSpacing / 2
        leftEye.position = CGPoint(x: leftX, y: 50)
        rightEye.position = CGPoint(x: rightX, y: 50)
        leftEye.setAffineTransform(CGAffineTransform(rotationAngle: -identity.eyeTilt))
        rightEye.setAffineTransform(CGAffineTransform(rotationAngle: identity.eyeTilt))
        setCapsule(leftEye, width: 8, height: identity.eyeHeight)
        setCapsule(rightEye, width: 8, height: identity.eyeHeight)
        CATransaction.commit()
    }

    private func updateColor(kind: AgentKind, colorIndex: Int?, celebrating: Bool,
                             needsAttention: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.28 : 0)
        let base = colorIndex.map(IslandPalette.project) ?? IslandPalette.nsColor(kind)
        body.fillColor = (celebrating ? NSColor.systemMint : base).cgColor
        body.strokeColor = (needsAttention ? NSColor.systemOrange : NSColor.black.withAlphaComponent(0.28)).cgColor
        body.lineWidth = needsAttention ? 2.5 : 1.5
        CATransaction.commit()
    }

    private func applyExpression(action: AgentActivityDetail.Action, celebrating: Bool,
                                 needsAttention: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.24 : 0)
        for eye in [leftEye, rightEye] {
            eye.strokeColor = nil
            eye.fillColor = NSColor(white: 0.035, alpha: 0.88).cgColor
            eye.lineWidth = 0
        }
        if celebrating {
            setHappyEye(leftEye)
            setHappyEye(rightEye)
        } else if needsAttention {
            setCapsule(leftEye, width: 11, height: 14)
            setCapsule(rightEye, width: 11, height: 14)
        } else if action == .compacting {
            setCapsule(leftEye, width: 13, height: 6)
            setCapsule(rightEye, width: 13, height: 6)
        } else {
            setCapsule(leftEye, width: 8, height: currentIdentity.eyeHeight)
            setCapsule(rightEye, width: 8, height: currentIdentity.eyeHeight)
        }
        CATransaction.commit()
    }

    private func startMotion(kind: AgentKind, action: AgentActivityDetail.Action, needsAttention: Bool) {
        let breathe = CABasicAnimation(keyPath: "transform.translation.y")
        breathe.fromValue = 1.2
        breathe.toValue = -1.2
        breathe.duration = kind == .codex ? 1.8 : 2.05
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        floating.add(breathe, forKey: "breathe")

        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.1, 1, 1, 0.12, 1, 1]
        blink.keyTimes = [0, 0.64, 0.665, 0.69, 0.75, 0.775, 0.8, 1]
        blink.duration = kind == .codex ? 5.3 : 6.1
        blink.repeatCount = .infinity
        eyes.add(blink, forKey: "blink")

        // Waiting is a held expression, not simulated work. Its reaction is
        // finite and the avatar keeps only the shared breathing/blinking.
        if needsAttention { return }
        if action == .editing || action == .tool {
            let focus = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            focus.values = [-0.018, 0.022, -0.012, 0.018, -0.018]
            focus.duration = action == .editing ? 1.05 : 1.35
            focus.repeatCount = .infinity
            focus.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bodyPose.add(focus, forKey: "focus")
        } else if action == .reading {
            let scan = CAKeyframeAnimation(keyPath: "transform.translation.x")
            scan.values = [-3, 3, -3, 3, 0]
            scan.keyTimes = [0, 0.14, 0.54, 0.68, 1]
            scan.duration = 3.5
            scan.repeatCount = .infinity
            eyes.add(scan, forKey: "read")
        } else if action == .compacting {
            let squash = CABasicAnimation(keyPath: "transform.scale.x")
            squash.fromValue = 1
            squash.toValue = 0.72
            squash.duration = 0.78
            squash.autoreverses = true
            squash.repeatCount = .infinity
            squash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bodyPose.add(squash, forKey: "compact")
        }
    }

    private func playReaction(celebrating: Bool, needsAttention: Bool) {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, celebrating ? 1.13 : 1.08, 0.97, 1]
        pop.keyTimes = [0, 0.34, 0.7, 1]
        pop.duration = 0.48
        bodyPose.add(pop, forKey: needsAttention ? "attention" : "reaction")

        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, celebrating ? -7 : -4, 1, 0]
        bounce.duration = 0.52
        bounce.isAdditive = true
        floating.add(bounce, forKey: "greeting")
    }

    func stopMotion() {
        for part in [floating, bodyPose, face, eyes, leftEye, rightEye] { part.removeAllAnimations() }
        motionEnabled = false
    }

    private func setCapsule(_ eye: CAShapeLayer, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: (12 - width) / 2, y: (22 - height) / 2, width: width, height: height)
        eye.path = CGPath(roundedRect: rect, cornerWidth: min(width, height) / 2,
            cornerHeight: min(width, height) / 2, transform: nil)
    }

    private func setHappyEye(_ eye: CAShapeLayer) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1.5, y: 13))
        path.addCurve(to: CGPoint(x: 10.5, y: 13), control1: CGPoint(x: 4, y: 8), control2: CGPoint(x: 8, y: 8))
        eye.path = path
        eye.fillColor = nil
        eye.strokeColor = NSColor(white: 0.035, alpha: 0.88).cgColor
        eye.lineWidth = 3.5
        eye.lineCap = .round
    }

    private func fallbackSeed(_ kind: AgentKind) -> UInt64 {
        kind == .codex ? 0xC0DE_5EED : 0xC1A0_DE5E
    }
}

private struct IslandBlobGlyphShape: Shape {
    let silhouette: IslandBlobSilhouette
    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(a: rect.width / 100, b: 0, c: 0,
            d: rect.height / 100, tx: rect.minX, ty: rect.minY)
        return Path(IslandBlobGeometry.path(silhouette).copy(using: &transform) ?? CGMutablePath())
    }
}

/// Small session faces are static. Only the featured character animates.
struct IslandAgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 24
    var colorIndex: Int? = nil
    var avatarSeed: UInt64? = nil
    private var color: Color {
        colorIndex.map { Color(nsColor: IslandPalette.project($0)) } ?? IslandPalette.color(kind)
    }
    private var identity: IslandBlobIdentity {
        IslandBlobIdentity(seed: avatarSeed ?? (kind == .codex ? 0xC0DE_5EED : 0xC1A0_DE5E))
    }
    var body: some View {
        let scale = size / 100
        return ZStack {
            IslandBlobGlyphShape(silhouette: identity.silhouette)
                .fill(color)
                .overlay(IslandBlobGlyphShape(silhouette: identity.silhouette)
                    .stroke(.black.opacity(0.28), lineWidth: max(0.6, size * 0.015)))
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule()
                    .fill(.black.opacity(0.82))
                    .frame(width: max(1.6, size * 0.08), height: max(3.8, identity.eyeHeight * scale))
                    .rotationEffect(.radians(Double(identity.eyeTilt * side)))
                    .offset(x: identity.eyeSpacing * scale * CGFloat(side) / 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
