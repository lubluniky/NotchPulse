import SwiftUI
import AppKit
import QuartzCore

/// Small status light. Animations run as Core Animation layer animations in the render
/// server, so an always-on pulse costs ~0% app CPU (no SwiftUI frame-by-frame updates).
struct StatusOrb: View {
    enum Style: Equatable {
        case running      // green, slow breathing glow
        case attention    // amber, radar ping + pulse — the "needs you" signal
        case failed       // red, static
        case completed    // dim white, static
        case idle         // very dim, static
        case offline      // hollow ring
    }

    var style: Style
    var diameter: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The layer view is larger than the dot so halos aren't clipped; hosting it in an
        // overlay keeps the layout footprint exactly `diameter`.
        let canvas = diameter * 3
        Color.clear
            .frame(width: diameter, height: diameter)
            .overlay(
                OrbLayerView(style: style, diameter: diameter, animated: !reduceMotion)
                    .frame(width: canvas, height: canvas)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    static func style(for state: AgentState) -> Style {
        switch state {
        case .running:    return .running
        case .needsInput: return .attention
        case .failed:     return .failed
        case .completed:  return .completed
        case .idle:       return .idle
        }
    }
}

private struct OrbLayerView: NSViewRepresentable {
    var style: StatusOrb.Style
    var diameter: CGFloat
    var animated: Bool

    func makeNSView(context: Context) -> OrbNSView { OrbNSView() }

    func updateNSView(_ view: OrbNSView, context: Context) {
        view.configure(style: style, diameter: diameter, animated: animated)
    }
}

final class OrbNSView: NSView {
    private let halo = CALayer()
    private let core = CALayer()
    private var style: StatusOrb.Style = .idle
    private var diameter: CGFloat = 8
    private var animated = true
    private var configured = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(halo)
        layer?.addSublayer(core)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(style: StatusOrb.Style, diameter: CGFloat, animated: Bool) {
        guard !configured || style != self.style || diameter != self.diameter || animated != self.animated else { return }
        configured = true
        self.style = style
        self.diameter = diameter
        self.animated = animated
        applyAppearance()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        for l in [halo, core] {
            l.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            l.cornerRadius = diameter / 2
            l.position = c
        }
        core.shadowPath = CGPath(ellipseIn: core.bounds, transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer animations are dropped when a layer leaves the tree; re-arm.
        if window != nil { applyAppearance() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        halo.contentsScale = scale
        core.contentsScale = scale
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.removeAllAnimations()
        core.removeAllAnimations()
        needsLayout = true

        let color: NSColor
        switch style {
        case .running:   color = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
        case .attention: color = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
        case .failed:    color = NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
        case .completed: color = NSColor(white: 1, alpha: 0.45)
        case .idle:      color = NSColor(white: 1, alpha: 0.25)
        case .offline:   color = NSColor(white: 1, alpha: 0.3)
        }

        core.backgroundColor = style == .offline ? NSColor.clear.cgColor : color.cgColor
        core.borderColor = color.cgColor
        core.borderWidth = style == .offline ? 1.2 : 0
        core.opacity = 1
        core.shadowColor = color.cgColor
        core.shadowOffset = .zero
        core.shadowRadius = 0
        core.shadowOpacity = 0
        halo.backgroundColor = color.cgColor
        halo.opacity = 0
        halo.transform = CATransform3DIdentity

        switch style {
        case .running:
            core.shadowOpacity = 0.9
            core.shadowRadius = 2.5
            if animated {
                // Slow breath: glow swells and the dot dims slightly.
                let glow = CABasicAnimation(keyPath: "shadowRadius")
                glow.fromValue = 1.0; glow.toValue = diameter * 0.55
                let dim = CABasicAnimation(keyPath: "opacity")
                dim.fromValue = 0.7; dim.toValue = 1.0
                let group = CAAnimationGroup()
                group.animations = [glow, dim]
                group.duration = 1.8
                group.autoreverses = true
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                core.add(group, forKey: "breath")
            }
        case .attention:
            core.shadowOpacity = 1
            core.shadowRadius = 3
            if animated {
                // Radar ping: halo expands and fades, once per beat.
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0; scale.toValue = 2.7
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.55; fade.toValue = 0.0
                let ping = CAAnimationGroup()
                ping.animations = [scale, fade]
                ping.duration = 1.5
                ping.repeatCount = .infinity
                ping.timingFunction = CAMediaTimingFunction(name: .easeOut)
                halo.add(ping, forKey: "ping")

                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0; pulse.toValue = 0.75
                pulse.duration = 0.75
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                core.add(pulse, forKey: "pulse")
            } else {
                // Reduced motion: a steady soft ring instead of the ping.
                halo.opacity = 0.25
                halo.transform = CATransform3DMakeScale(1.9, 1.9, 1)
            }
        case .failed:
            core.shadowOpacity = 0.6
            core.shadowRadius = 2
        default:
            break
        }
        CATransaction.commit()
    }
}
