import AppKit
import QuartzCore

@MainActor final class WindowHighlight {
    private var panel: NSPanel?
    private var outline: CAShapeLayer?

    static func appKitFrame(_ quartz: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    func show(quartzFrame: CGRect) {
        let frame = Self.appKitFrame(quartzFrame, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height).insetBy(dx: -5, dy: -5)
        if panel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.hasShadow = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            let border = CAShapeLayer()
            border.fillColor = NSColor.clear.cgColor
            border.strokeColor = NSColor.controlAccentColor.cgColor
            border.lineWidth = 3
            border.shadowColor = NSColor.controlAccentColor.cgColor
            border.shadowOpacity = 0.65; border.shadowRadius = 5; border.shadowOffset = .zero
            view.layer?.addSublayer(border); panel.contentView = view
            self.panel = panel; outline = border
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.35; pulse.toValue = 1
                pulse.duration = 0.75; pulse.autoreverses = true; pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                border.add(pulse, forKey: "breathing")
            }
        }
        panel?.setFrame(frame, display: true)
        outline?.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 4, dy: 4), cornerWidth: 12, cornerHeight: 12, transform: nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        outline?.removeAllAnimations(); panel?.orderOut(nil)
        outline = nil; panel = nil
    }
}
