import AppKit
import Metal
import QuartzCore

/// Ultra-subtle native macOS 27 HDR / EDR accent & focus ring overlay for the active tab pill.
/// Matches Real Safari's measured `#2A2A2A` over `#212121` dark-mode active tab (+0.037 subtle lift)
/// with ZERO harsh gray-white outline line, letting `NSGlassEffectView` render its native specular rim.
final class HDRPillHighlightView: NSView {
    private let borderLayer = CAShapeLayer()
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?

    var cornerRadius: CGFloat = SafariMetrics.tabPillCornerRadius {
        didSet { needsLayout = true }
    }

    var isFocused: Bool = false {
        didSet {
            updateHDRColors()
            needsLayout = true
        }
    }

    var isLightInkOnDark: Bool = false {
        didSet { updateHDRColors() }
    }

    var accentTintColor: NSColor? {
        didSet {
            // Re-rendering the Metal EDR sheen is expensive; skip when the colour did not actually change.
            if let a = oldValue, let b = accentTintColor, a == b { return }
            if oldValue == nil && accentTintColor == nil { return }
            updateHDRColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true

        // Whisper-subtle EDR CAMetalLayer scaled cleanly to screen EDR headroom (never washes out dark glass)
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue() {
            let ml = CAMetalLayer()
            ml.device = device
            ml.pixelFormat = .rgba16Float
            ml.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ml.wantsExtendedDynamicRangeContent = true
            ml.isOpaque = false
            ml.framebufferOnly = false
            ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            ml.edrMetadata = nil
            ml.opacity = 0.02
            if #available(macOS 26.0, *) {
                ml.preferredDynamicRange = .constrainedHigh
            }
            root.addSublayer(ml)
            self.metalLayer = ml
            self.commandQueue = queue
        }

        // Clean uniform 0.5pt pill perimeter stroke (zero uneven side-arc streaks!)
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 0.5
        root.addSublayer(borderLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScreenChange),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        updateHDRColors()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleScreenChange() {
        metalLayer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        updateHDRColors()
        renderMetalEDRSheen()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous

        borderLayer.frame = bounds
        let inset: CGFloat = 0.25
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(0, cornerRadius - inset),
            cornerHeight: max(0, cornerRadius - inset),
            transform: nil
        )

        if let ml = metalLayer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            ml.frame = bounds
            ml.cornerRadius = cornerRadius
            ml.cornerCurve = .continuous
            ml.contentsScale = scale
            let pw = max(1, Int(bounds.width * scale))
            let ph = max(1, Int(bounds.height * scale))
            if Int(ml.drawableSize.width) != pw || Int(ml.drawableSize.height) != ph {
                ml.drawableSize = CGSize(width: pw, height: ph)
                if !isFocused {
                    renderMetalEDRSheen()
                }
            }
        }
        CATransaction.commit()
    }

    func updateHDRColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isFocused {
            // Strictly SDR when address bar is focused (ZERO HDR / EDR glow)
            isHidden = true
            borderLayer.strokeColor = NSColor.clear.cgColor
            borderLayer.lineWidth = 0.0
            metalLayer?.isHidden = true
            metalLayer?.opacity = 0.0
            metalLayer?.wantsExtendedDynamicRangeContent = false
            if #available(macOS 26.0, *) {
                metalLayer?.preferredDynamicRange = .standard
                layer?.preferredDynamicRange = .standard
            }
            CATransaction.commit()
            return
        }

        isHidden = false
        if #available(macOS 26.0, *) {
            // Let native NSGlassEffectView render the smooth Liquid Glass edge with zero painted border overlay.
            borderLayer.strokeColor = NSColor.clear.cgColor
            borderLayer.lineWidth = 0.0
            metalLayer?.preferredDynamicRange = .constrainedHigh
            layer?.preferredDynamicRange = .constrainedHigh
        } else if !isLightInkOnDark {
            borderLayer.strokeColor = NSColor.black.withAlphaComponent(0.06).cgColor
            borderLayer.lineWidth = 0.5
        } else {
            borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
            borderLayer.lineWidth = 0.5
        }
        metalLayer?.isHidden = false
        metalLayer?.wantsExtendedDynamicRangeContent = true
        metalLayer?.opacity = isLightInkOnDark ? 0.02 : 0.035
        CATransaction.commit()

        renderMetalEDRSheen()
    }

    private func renderMetalEDRSheen() {
        guard !isFocused,
              let ml = metalLayer,
              let queue = commandQueue,
              ml.drawableSize.width >= 2,
              ml.drawableSize.height >= 2,
              let drawable = ml.nextDrawable(),
              let cmdBuffer = queue.makeCommandBuffer() else {
            return
        }

        let screen = window?.screen ?? NSScreen.main
        let exposure = Double(SafariMetrics.activeTabLinearExposure(for: screen))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: exposure,
            green: exposure,
            blue: exposure,
            alpha: isLightInkOnDark ? 0.08 : 0.14
        )

        if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}

/// Convenience factory for subtle HDR-lifted accents & active tab glass tint matching Real Safari 27.3.
enum HDRColorFactory {
    static func accentColor(for screen: NSScreen?, alpha: CGFloat = 1.0) -> NSColor {
        let exposure = SafariMetrics.accentLinearExposure(for: screen)
        if #available(macOS 26.0, *) {
            return NSColor(red: 0.0, green: 0.478, blue: 1.0, alpha: alpha, linearExposure: exposure)
        }
        return NSColor.systemBlue.withAlphaComponent(alpha)
    }

    /// Returns `nil` on white light pages so `NSGlassEffectView` renders native raised `#FEFDFE` white Liquid Glass,
    /// and a restrained `+0.037` lift (`#2A2A2A` over `#212121`) on dark pages without washing out!
    static func activeTabTint(base: NSColor?, lightOnDark: Bool, screen: NSScreen?) -> NSColor? {
        let exposure = SafariMetrics.activeTabLinearExposure(for: screen)
        guard let base else { return nil }
        let srgb = base.usingColorSpace(.sRGB) ?? base

        if lightOnDark {
            if #available(macOS 26.0, *) {
                // Restrained subtle lift (~#2A2A2A over #212121 track, alpha 0.10) — never washed-out grey!
                let r = min(1.0, srgb.redComponent * 0.6 + 0.12)
                let g = min(1.0, srgb.greenComponent * 0.6 + 0.12)
                let b = min(1.0, srgb.blueComponent * 0.6 + 0.13)
                return NSColor(red: r, green: g, blue: b, alpha: 0.10, linearExposure: exposure)
            }
            return NSColor.white.withAlphaComponent(0.08)
        } else {
            // On near-white light pages, nil tint lets native NSGlassEffectView shine as crisp raised #FEFDFE glass!
            let isNearWhite = srgb.redComponent > 0.92 && srgb.greenComponent > 0.92 && srgb.blueComponent > 0.92
            if isNearWhite {
                return nil
            }
            return srgb.withAlphaComponent(0.06)
        }
    }
}
