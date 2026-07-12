import AppKit
import QuartzCore
import SwiftUI

enum SmartCareMotionMode: Equatable {
    case idle
    case scanning
    case cleaning
    case complete
}

enum SmartCareMotionPalette {
    static let blueVector = SIMD4<Float>(0.14, 0.48, 0.98, 1)
    static let tealVector = SIMD4<Float>(0.09, 0.69, 0.56, 1)
    static let amberVector = SIMD4<Float>(0.95, 0.58, 0.16, 1)

    static let blue = nsColor(blueVector)
    static let teal = nsColor(tealVector)
    static let amber = nsColor(amberVector)

    static let blueColor = swiftUIColor(blueVector)
    static let tealColor = swiftUIColor(tealVector)
    static let amberColor = swiftUIColor(amberVector)

    private static func nsColor(_ components: SIMD4<Float>) -> NSColor {
        NSColor(
            red: CGFloat(components.x),
            green: CGFloat(components.y),
            blue: CGFloat(components.z),
            alpha: CGFloat(components.w)
        )
    }

    private static func swiftUIColor(_ components: SIMD4<Float>) -> Color {
        Color(
            red: Double(components.x),
            green: Double(components.y),
            blue: Double(components.z),
            opacity: Double(components.w)
        )
    }
}

struct SmartCareAmbientMotionView: NSViewRepresentable {
    let mode: SmartCareMotionMode
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SmartCareAmbientHostView {
        let view = SmartCareAmbientHostView()
        view.configure(mode: mode, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: SmartCareAmbientHostView, context: Context) {
        nsView.configure(mode: mode, reduceMotion: reduceMotion)
    }
}

struct SmartCareCoreMotionView: NSViewRepresentable {
    let mode: SmartCareMotionMode
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SmartCareCoreHostView {
        let view = SmartCareCoreHostView()
        view.configure(mode: mode, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: SmartCareCoreHostView, context: Context) {
        nsView.configure(mode: mode, reduceMotion: reduceMotion)
    }
}

final class SmartCareAmbientHostView: NSView {
    private let colorField = CAGradientLayer()
    private let grid = CAShapeLayer()
    private let contours = CAShapeLayer()
    private let sweep = CAGradientLayer()
    private var mode: SmartCareMotionMode = .idle
    private var reduceMotion = false
    private var isConfigured = false
    private var lastSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(colorField)
        layer?.addSublayer(grid)
        layer?.addSublayer(contours)
        layer?.addSublayer(sweep)
        grid.fillColor = nil
        contours.fillColor = nil
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorField.frame = bounds
        grid.frame = bounds
        contours.frame = bounds
        sweep.frame = CGRect(x: -220, y: 0, width: 220, height: bounds.height)
        grid.path = makeGridPath(in: bounds)
        contours.path = makeContourPath(in: bounds)
        CATransaction.commit()
        restartSweep()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func configure(mode: SmartCareMotionMode, reduceMotion: Bool) {
        let changed = self.mode != mode || self.reduceMotion != reduceMotion
        guard !isConfigured || changed else { return }
        isConfigured = true
        self.mode = mode
        self.reduceMotion = reduceMotion
        updateColors()
        restartSweep()
    }

    private func updateColors() {
        let blue = SmartCareMotionPalette.blue
        let teal = SmartCareMotionPalette.teal
        let amber = SmartCareMotionPalette.amber
        let intensity: CGFloat = mode == .scanning ? 0.82 : 0.74

        colorField.colors = [
            blue.withAlphaComponent(0.11 * intensity).cgColor,
            NSColor.clear.cgColor,
            teal.withAlphaComponent(0.075 * intensity).cgColor,
            amber.withAlphaComponent(0.045 * intensity).cgColor
        ]
        colorField.locations = [0, 0.38, 0.72, 1]
        colorField.startPoint = CGPoint(x: 0, y: 0)
        colorField.endPoint = CGPoint(x: 1, y: 1)
        grid.strokeColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        grid.lineWidth = 0.6
        contours.strokeColor = teal.withAlphaComponent(mode == .scanning ? 0.09 : 0.075).cgColor
        contours.lineWidth = 1
        let suppressSweep = mode == .idle || mode == .scanning
        let sweepBlueAlpha: CGFloat = suppressSweep ? 0 : 0.015
        let sweepTealAlpha: CGFloat = suppressSweep ? 0 : 0.08
        sweep.colors = [
            NSColor.clear.cgColor,
            blue.withAlphaComponent(sweepBlueAlpha).cgColor,
            teal.withAlphaComponent(sweepTealAlpha).cgColor,
            NSColor.clear.cgColor
        ]
        sweep.locations = [0, 0.3, 0.7, 1]
    }

    private func restartSweep() {
        sweep.removeAllAnimations()
        guard !reduceMotion, mode != .idle, mode != .scanning, bounds.width > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sweep.position.x = bounds.midX
            CATransaction.commit()
            return
        }

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -110
        animation.toValue = bounds.width + 110
        animation.duration = 7.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(animation, forKey: "smart-care-sweep")
    }

    private func makeGridPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let spacing: CGFloat = 54
        var x: CGFloat = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height * 0.42, y: rect.maxY))
            x += spacing
        }
        var y: CGFloat = 28
        while y < rect.height {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return path
    }

    private func makeContourPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }
        for index in 0..<5 {
            let offset = CGFloat(index) * 34
            let y = rect.height * 0.58 + offset
            path.move(to: CGPoint(x: -20, y: y))
            path.addCurve(
                to: CGPoint(x: rect.width + 20, y: y - 46),
                control1: CGPoint(x: rect.width * 0.25, y: y - 72),
                control2: CGPoint(x: rect.width * 0.68, y: y + 30)
            )
        }
        return path
    }
}

final class SmartCareCoreHostView: NSView {
    private let outerTrack = CAShapeLayer()
    private let innerTrack = CAShapeLayer()
    private let blueArc = CAShapeLayer()
    private let tealArc = CAShapeLayer()
    private let amberArc = CAShapeLayer()
    private let pulse = CAShapeLayer()
    private var mode: SmartCareMotionMode = .idle
    private var reduceMotion = false
    private var isConfigured = false
    private var lastSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [pulse, outerTrack, innerTrack, blueArc, tealArc, amberArc].forEach {
            $0.fillColor = nil
            $0.lineCap = .round
            layer?.addSublayer($0)
        }
        blueArc.strokeStart = 0.04
        blueArc.strokeEnd = 0.34
        tealArc.strokeStart = 0.46
        tealArc.strokeEnd = 0.72
        amberArc.strokeStart = 0.82
        amberArc.strokeEnd = 0.94
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        let size = min(bounds.width, bounds.height)
        let frame = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [pulse, outerTrack, innerTrack, blueArc, tealArc, amberArc] {
            layer.frame = bounds
        }
        let outerPath = CGPath(ellipseIn: frame.insetBy(dx: 13, dy: 13), transform: nil)
        let innerPath = CGPath(ellipseIn: frame.insetBy(dx: 34, dy: 34), transform: nil)
        pulse.path = CGPath(ellipseIn: frame.insetBy(dx: 4, dy: 4), transform: nil)
        outerTrack.path = outerPath
        blueArc.path = outerPath
        tealArc.path = outerPath
        amberArc.path = outerPath
        innerTrack.path = innerPath
        CATransaction.commit()
        restartAnimations()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func configure(mode: SmartCareMotionMode, reduceMotion: Bool) {
        let changed = self.mode != mode || self.reduceMotion != reduceMotion
        guard !isConfigured || changed else { return }
        isConfigured = true
        self.mode = mode
        self.reduceMotion = reduceMotion
        updateColors()
        restartAnimations()
    }

    private func updateColors() {
        let blue = SmartCareMotionPalette.blue
        let teal = SmartCareMotionPalette.teal
        let amber = SmartCareMotionPalette.amber
        outerTrack.strokeColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        innerTrack.strokeColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        outerTrack.lineWidth = 11
        innerTrack.lineWidth = 1
        blueArc.strokeColor = blue.cgColor
        tealArc.strokeColor = teal.cgColor
        amberArc.strokeColor = amber.cgColor
        blueArc.lineWidth = mode == .scanning ? 13 : 10
        tealArc.lineWidth = mode == .scanning ? 9 : 7
        amberArc.lineWidth = 5
        pulse.strokeColor = (mode == .cleaning ? teal : blue).withAlphaComponent(0.22).cgColor
        pulse.lineWidth = 1.4
    }

    private func restartAnimations() {
        [pulse, blueArc, tealArc, amberArc].forEach { $0.removeAllAnimations() }
        guard !reduceMotion, bounds.width > 0 else { return }

        addRotation(to: blueArc, duration: mode == .scanning ? 1.65 : 5.8, clockwise: true)
        addRotation(to: tealArc, duration: mode == .scanning ? 3.2 : 8.4, clockwise: false)
        addRotation(to: amberArc, duration: mode == .scanning ? 5.4 : 11.0, clockwise: true)

        let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
        pulseAnimation.fromValue = 0.97
        pulseAnimation.toValue = 1.035
        pulseAnimation.duration = mode == .scanning ? 1.15 : 2.4
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.add(pulseAnimation, forKey: "smart-care-pulse")
    }

    private func addRotation(to layer: CALayer, duration: CFTimeInterval, clockwise: Bool) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = clockwise ? Double.pi * 2 : -Double.pi * 2
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "smart-care-rotation")
    }
}
