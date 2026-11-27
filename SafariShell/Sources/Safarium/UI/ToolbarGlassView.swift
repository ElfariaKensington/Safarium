import AppKit
import QuartzCore

/// The toolbar's glass. The web view runs behind the toolbar (the page carries a matching top inset, see
/// `installUnderToolbarInset` in BrowserCore), so this view only has to frost whatever is behind it:
///
/// - y = 0 ..< `SafariMetrics.toolbarHeight`: full blur plus a tint of the page's top colour.
/// - a short `edgeHeight` below the toolbar where blur and tint fade out, so the toolbar has a soft bottom edge
///   instead of a line.
///
/// It has no scroll-dependent states: at the top of a page the glass sits over the page's own background
/// (the inset), and scrolled content simply slides under it.
final class ToolbarGlassView: NSView {
    enum EdgeOrientation {
        case top
        case left
    }

    /// Soft fade below the toolbar (standard mode).
    static let edgeHeight: CGFloat = 10.0
    static var totalHeight: CGFloat { SafariMetrics.toolbarHeight + edgeHeight }
    /// Soft fade for Refractive Liquid Glass mode so glass disappears seamlessly without intruding into the page.
    static let refractiveEdgeHeight: CGFloat = 26.0
    static var refractiveTotalHeight: CGFloat { SafariMetrics.toolbarHeight + refractiveEdgeHeight }
    static var activeTotalHeight: CGFloat {
        BrowserSettings.shared.refractiveGlassToolbar ? refractiveTotalHeight : totalHeight
    }

    static let blurRadius: Double = 18.0
    static let refractiveDisplacementAmount: Double = 6.5
    static let refractiveChromaticAmount: Double = 3.98
    static let refractiveSaturationAmount: Double = 1.98
    static let refractiveRippleStrength: Double = 0.69
    static let refractiveRippleFrequency: Double = 4.8
    static let refractiveVerticalCurve: Double = 1.50

    let orientation: EdgeOrientation
    private var backdropLayer: CALayer?
    private let reflectionOverlayView = PassthroughReflectionView()
    private let fixedReflectionContainerLayer = CALayer()
    private var fixedReflectionBackdropLayer: CALayer?
    private let fixedReflectionMaskLayer = CAGradientLayer()
    private let tintLayer = CAGradientLayer()
    private var liquidGlassView: NSView?
    private let liquidGlassMaskLayer = CAGradientLayer()
    private let backdropFadeMaskLayer = CAGradientLayer()
    private let lShapeLiquidMaskLayer = CALayer()
    private let lShapeBackdropMaskLayer = CALayer()
    private let lShapeTintMaskLayer = CALayer()
    private var fallbackEffectView: NSVisualEffectView?
    private var builtForExtent: CGFloat = -1
    private var builtForSize: CGSize = .zero
    private var isRefractiveGlassEnabled: Bool = false
    private var appliedRefractiveFrost: Double = -1.0
    private var hasFixedHeader: Bool = false
    var isShowingFixedHeader: Bool { hasFixedHeader }
    private var lastPrefersLightInk: Bool = false
    private var lastSampledColor: NSColor?
    private var lastCustomVeilColor: NSColor?
    private var lastFixedHeaderColor: NSColor?

    /// Non-zero when Vertical tab layout is active: extends the single unified glass surface down
    /// the left edge (`0 ..< verticalRailWidth`) as one seamless L-shape with the top toolbar.
    var verticalRailWidth: CGFloat = 0 {
        didSet {
            guard abs(verticalRailWidth - oldValue) > 0.5 else { return }
            builtForSize = .zero
            needsLayout = true
            updateBlurMask()
        }
    }

    /// Top toolbar stack height (`52pt` compact/vertical, `86pt` separate) used as the bottom edge
    /// of the top glass band when `verticalRailWidth > 0`.
    var topBarHeight: CGFloat = SafariMetrics.toolbarHeight {
        didSet {
            guard abs(topBarHeight - oldValue) > 0.5 else { return }
            builtForSize = .zero
            needsLayout = true
            updateBlurMask()
        }
    }

    init(orientation: EdgeOrientation = .top, frame frameRect: NSRect = .zero) {
        self.orientation = orientation
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        buildLayers()
        apply(prefersLightInk: false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Overhang applied to `liquidGlassView` along its open sides so `NSGlassEffectView`'s
    /// curved borders lie outside `ToolbarGlassView.bounds` while preserving its optical edge refraction.
    private static let liquidGlassOverhang: CGFloat = 56.0

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer?.frame = bounds
        reflectionOverlayView.frame = bounds
        fixedReflectionContainerLayer.frame = bounds
        fixedReflectionBackdropLayer?.frame = bounds
        fixedReflectionMaskLayer.frame = bounds
        tintLayer.frame = bounds
        let o = Self.liquidGlassOverhang
        let expandedGlassFrame: NSRect
        if verticalRailWidth > 0.5 {
            expandedGlassFrame = NSRect(x: -o, y: -o, width: bounds.width + o * 2, height: bounds.height + o)
        } else if orientation == .left {
            expandedGlassFrame = NSRect(x: 0, y: -o, width: bounds.width, height: bounds.height + o * 2)
        } else {
            expandedGlassFrame = NSRect(x: -o, y: 0, width: bounds.width + o * 2, height: bounds.height)
        }
        liquidGlassView?.frame = expandedGlassFrame
        liquidGlassMaskLayer.frame = NSRect(origin: .zero, size: expandedGlassFrame.size)
        lShapeLiquidMaskLayer.frame = NSRect(origin: .zero, size: expandedGlassFrame.size)
        backdropFadeMaskLayer.frame = bounds
        lShapeBackdropMaskLayer.frame = bounds
        let extent = (orientation == .left) ? bounds.width : bounds.height
        let sizeChanged = abs(extent - builtForExtent) > 0.5 || abs(bounds.width - builtForSize.width) > 0.5 || abs(bounds.height - builtForSize.height) > 0.5
        if sizeChanged {
            updateBlurMask()
        }
        CATransaction.commit()
        if sizeChanged && bounds.height > 1 {
            // Recompute tintLayer gradient stops for the exact laid-out height (critical when switching
            // between 92pt top-only mode and full-height L-shape vertical mode, or resizing the window).
            apply(
                prefersLightInk: lastPrefersLightInk,
                sampledColor: lastSampledColor,
                customVeilColor: lastCustomVeilColor,
                fixedHeaderColor: lastFixedHeaderColor,
                animated: false
            )
        }
    }

    // MARK: - Shape

    /// C² smoothstep falloff: 1 at `u <= 0`, 0 at `u >= 1`, zero slope and curvature at both ends (no banding).
    static func quinticFalloff(_ u: Double) -> Double {
        let c = min(1.0, max(0.0, u))
        return 1.0 - c * c * c * (c * (c * 6.0 - 15.0) + 10.0)
    }

    /// Opacity profile from the top of the view (y = 0) to its bottom: solid through the toolbar, then a soft fade.
    static func profile(atY y: Double, viewHeight h: Double) -> Double {
        let solidEnd = max(0, h - Double(edgeHeight))
        if y <= solidEnd { return 1.0 }
        return quinticFalloff((y - solidEnd) / max(1, h - solidEnd))
    }

    // MARK: - Colour

    /// `customVeilColor`: native pages (Start Page, History, error page) pass their own colour.
    /// `fixedHeaderColor` / `sampledColor`: the page's top colour.
    func apply(
        prefersLightInk: Bool,
        sampledColor: NSColor? = nil,
        customVeilColor: NSColor? = nil,
        fixedHeaderColor: NSColor? = nil,
        animated: Bool
    ) {
        lastPrefersLightInk = prefersLightInk
        lastSampledColor = sampledColor
        lastCustomVeilColor = customVeilColor
        lastFixedHeaderColor = fixedHeaderColor

        let refractive = BrowserSettings.shared.refractiveGlassToolbar
        let frost = BrowserSettings.shared.refractiveGlassFrost
        if refractive != isRefractiveGlassEnabled || (refractive && abs(frost - appliedRefractiveFrost) > 0.05) {
            isRefractiveGlassEnabled = refractive
            appliedRefractiveFrost = frost
            updateBackdropFiltersForMode()
        }

        fallbackEffectView?.appearance = NSAppearance(named: prefersLightInk ? .darkAqua : .aqua)

        let neutral = prefersLightInk
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let base: NSColor
        let strength: CGFloat
        if let customVeilColor {
            base = customVeilColor
            strength = refractive ? 0.08 : 0.24 // native pages: their wallpaper/background shows through clearly
        } else if let bar = fixedHeaderColor?.usingColorSpace(.sRGB) {
            // A fixed bar sits right under the toolbar, and the page paints a matching fixed veil
            // behind `0..toolbarHeight`. Keep real glass (blur + soft edge) with a subtle matching tint
            // so the toolbar and fixed bar blend into one continuous surface with zero brightness step.
            base = bar.withAlphaComponent(1)
            strength = refractive ? 0.12 : 0.32
        } else if let page = sampledColor?.usingColorSpace(.sRGB) {
            base = neutral.blended(withFraction: prefersLightInk ? 0.85 : 0.7, of: page) ?? page
            strength = refractive ? (prefersLightInk ? 0.10 : 0.06) : (prefersLightInk ? 0.72 : 0.66)
        } else {
            base = neutral
            strength = refractive ? (prefersLightInk ? 0.10 : 0.06) : (prefersLightInk ? 0.72 : 0.66)
        }

        let h = Double(max(bounds.height, refractive ? Self.refractiveTotalHeight : Self.totalHeight))
        let hasFixed = (fixedHeaderColor != nil) && (orientation == .top)
        let fixedHeaderChanged = (hasFixed != hasFixedHeader)
        hasFixedHeader = hasFixed
        if fixedHeaderChanged {
            updateBackdropFiltersForMode()
        }

        // Toolbar end position inside `ToolbarGlassView`: in L-shape vertical mode it is `topBarHeight`,
        // in top-only mode it is `h - activeEdge` (52pt compact, 86pt separate).
        let activeEdge = refractive ? Double(Self.refractiveEdgeHeight) : Double(Self.edgeHeight)
        let toolbarEnd: Double = (verticalRailWidth > 0.5)
            ? Double(topBarHeight)
            : max(1.0, h - activeEdge)

        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        if hasFixed, let bar = fixedHeaderColor?.usingColorSpace(.sRGB) {
            // Transition the toolbar's own background smoothly from clear/glass at the top (`y = 0`)
            // into the fixed bar's exact color & opacity at `toolbarEnd` (`y = 52`), ending strictly
            // at `toolbarEnd` so ZERO pixels invade the fixed bar below.
            let targetAlpha = max(0.35, min(1.0, bar.alphaComponent))
            let topAlpha: CGFloat = 0.0
            let mid1Alpha = targetAlpha * 0.22
            let mid2Alpha = targetAlpha * 0.68
            let endLoc = min(1.0, (toolbarEnd + 2.5) / h)
            let afterLoc = min(1.0, (toolbarEnd + 3.5) / h)
            let stops: [(Double, CGFloat)] = [
                (0.0, topAlpha),
                (endLoc * 0.30, mid1Alpha),
                (endLoc * 0.62, mid2Alpha),
                (endLoc * 0.84, targetAlpha),
                (endLoc, targetAlpha),
                (afterLoc, 0.0),
                (1.0, 0.0)
            ]
            for (loc, a) in stops {
                locations.append(NSNumber(value: loc))
                colors.append(bar.withAlphaComponent(a).cgColor)
            }
        } else if verticalRailWidth > 0.5 {
            // In full-height L-shape vertical mode, run the exact same top-toolbar gradient over
            // `0 ..< topBarHeight + activeEdge` (instead of stretching across the entire window height).
            let topSolid = Double(topBarHeight)
            let topTotal = min(h, topSolid + activeEdge)
            locations.append(0.0)
            colors.append(base.withAlphaComponent(strength).cgColor)
            locations.append(NSNumber(value: min(1.0, topSolid / h)))
            colors.append(base.withAlphaComponent(strength).cgColor)
            let fadeStops = 10
            for i in 1...fadeStops {
                let frac = Double(i) / Double(fadeStops)
                let yPos = topSolid + frac * (topTotal - topSolid)
                let a = strength * CGFloat(Self.quinticFalloff(frac))
                locations.append(NSNumber(value: min(1.0, yPos / h)))
                colors.append(base.withAlphaComponent(a).cgColor)
            }
            locations.append(1.0)
            colors.append(base.withAlphaComponent(0.0).cgColor)
        } else {
            let stops = 12
            for i in 0..<stops {
                let loc = Double(i) / Double(stops - 1)
                locations.append(NSNumber(value: loc))
                colors.append(base.withAlphaComponent(strength * CGFloat(Self.profile(atY: loc * h, viewHeight: h))).cgColor)
            }
        }

        if #available(macOS 26.0, *), let gv = liquidGlassView as? NSGlassEffectView {
            gv.style = .clear
            gv.cornerRadius = Self.refractiveEdgeHeight
            gv.appearance = NSAppearance(named: prefersLightInk ? .darkAqua : .aqua)
            gv.tintColor = nil
            gv.isHidden = !refractive
            gv.alphaValue = refractive ? 1.0 : 0.0
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? SafariMetrics.topEdgeTintAnimationDuration : 0)
        if !animated { CATransaction.setDisableActions(true) }
        backdropLayer?.opacity = 1
        fixedReflectionContainerLayer.opacity = 0
        fallbackEffectView?.alphaValue = refractive ? 0 : 1
        tintLayer.opacity = (refractive && !hasFixed) ? 0 : 1
        tintLayer.colors = colors
        tintLayer.locations = locations
        CATransaction.commit()
    }

    // MARK: - Layers

    private func buildLayers() {
        guard let root = layer else { return }
        if orientation == .left {
            tintLayer.startPoint = CGPoint(x: 0, y: 0.5)
            tintLayer.endPoint = CGPoint(x: 1, y: 0.5)
            liquidGlassMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
            liquidGlassMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
            backdropFadeMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
            backdropFadeMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            // Non-flipped layer space: y = 1 is the top of the view.
            tintLayer.startPoint = CGPoint(x: 0.5, y: 1)
            tintLayer.endPoint = CGPoint(x: 0.5, y: 0)
            liquidGlassMaskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            liquidGlassMaskLayer.endPoint = CGPoint(x: 0.5, y: 0)
            backdropFadeMaskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            backdropFadeMaskLayer.endPoint = CGPoint(x: 0.5, y: 0)
            fixedReflectionMaskLayer.startPoint = CGPoint(x: 0.5, y: 1)
            fixedReflectionMaskLayer.endPoint = CGPoint(x: 0.5, y: 0)
        }

        if let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
           let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
           filterClass.responds(to: NSSelectorFromString("filterWithType:")),
           let _ = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
               .takeUnretainedValue() as? NSObject {
            let backdrop = backdropClass.init()
            if backdrop.responds(to: NSSelectorFromString("setWindowServerAware:")) {
                backdrop.setValue(true, forKey: "windowServerAware")
            }
            if backdrop.responds(to: NSSelectorFromString("setScale:")) {
                backdrop.setValue(0.5, forKey: "scale")
            }
            root.addSublayer(backdrop)
            root.addSublayer(tintLayer)
            backdropLayer = backdrop
            installLiquidGlassViewIfAvailable()
            if orientation == .top {
                reflectionOverlayView.wantsLayer = true
                reflectionOverlayView.layer?.masksToBounds = true
                let reflBackdrop = backdropClass.init()
                if reflBackdrop.responds(to: NSSelectorFromString("setWindowServerAware:")) {
                    reflBackdrop.setValue(true, forKey: "windowServerAware")
                }
                if reflBackdrop.responds(to: NSSelectorFromString("setScale:")) {
                    reflBackdrop.setValue(1.0, forKey: "scale")
                }
                var reflFilters: [NSObject] = []
                if let disp = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "displacementMap")?
                    .takeUnretainedValue() as? NSObject {
                    disp.setValue(Self.fixedReflectionMaxShift, forKey: "inputAmount")
                    reflFilters.append(disp)
                }
                if let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                    .takeUnretainedValue() as? NSObject {
                    blur.setValue(12.0, forKey: "inputRadius")
                    blur.setValue(true, forKey: "inputNormalizeEdges")
                    reflFilters.append(blur)
                }
                reflBackdrop.filters = reflFilters
                // Keep reflBackdrop unmasked so WindowServer captures the full fixed header below seamY;
                // clip the blurred reflection strictly above seamY via fixedReflectionContainerLayer.mask.
                fixedReflectionContainerLayer.addSublayer(reflBackdrop)
                fixedReflectionContainerLayer.mask = fixedReflectionMaskLayer
                fixedReflectionContainerLayer.opacity = 0
                reflectionOverlayView.layer?.addSublayer(fixedReflectionContainerLayer)
                addSubview(reflectionOverlayView)
                fixedReflectionBackdropLayer = reflBackdrop
            }
            isRefractiveGlassEnabled = BrowserSettings.shared.refractiveGlassToolbar
            updateBackdropFiltersForMode()
            return
        }

        // No private backdrop API: a standard material with the same fade.
        let effect = NSVisualEffectView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        fallbackEffectView = effect
        root.addSublayer(tintLayer)
        installLiquidGlassViewIfAvailable()
        updateBlurMask()
    }

    private func installLiquidGlassViewIfAvailable() {
        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .clear
            gv.cornerRadius = Self.refractiveEdgeHeight
            gv.wantsLayer = true
            gv.layer?.mask = liquidGlassMaskLayer
            gv.isHidden = !BrowserSettings.shared.refractiveGlassToolbar
            addSubview(gv)
            liquidGlassView = gv
        }
    }

    private func updateBackdropFiltersForMode() {
        guard let backdrop = backdropLayer,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")) else {
            return
        }
        var filters: [NSObject] = []
        if isRefractiveGlassEnabled {
            // Tuned user profile: NSGlass(.clear) + Bipolar128 disp=6.5, chrom=3.98, blur=0, sat=1.98, tint=0, edge=40.
            if let disp = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "displacementMap")?
                .takeUnretainedValue() as? NSObject {
                disp.setValue(Self.refractiveDisplacementAmount, forKey: "inputAmount")
                filters.append(disp)
            }
            if let chrom = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "chromaticAberrationMap")?
                .takeUnretainedValue() as? NSObject {
                chrom.setValue(Self.refractiveChromaticAmount, forKey: "inputAmount")
                filters.append(chrom)
            }
            let frostRadius = BrowserSettings.shared.refractiveGlassFrost
            appliedRefractiveFrost = frostRadius
            if frostRadius > 0.05,
               let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                   .takeUnretainedValue() as? NSObject {
                blur.setValue(frostRadius, forKey: "inputRadius")
                blur.setValue(true, forKey: "inputNormalizeEdges")
                filters.append(blur)
            }
            if let saturate = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?
                .takeUnretainedValue() as? NSObject {
                saturate.setValue(Self.refractiveSaturationAmount, forKey: "inputAmount")
                filters.append(saturate)
            }
            backdrop.mask = backdropFadeMaskLayer
        } else {
            if let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject {
                blur.setValue(Self.blurRadius, forKey: "inputRadius")
                blur.setValue(true, forKey: "inputNormalizeEdges")
                filters.append(blur)
            }
            backdrop.mask = nil
        }
        backdrop.filters = filters
        if backdrop.responds(to: NSSelectorFromString("setScale:")) {
            backdrop.setValue(isRefractiveGlassEnabled ? 1.0 : 0.5, forKey: "scale")
        }
        builtForExtent = -1
        updateBlurMask()
    }

    /// Updates blur mask, 2D bipolar refraction map, and smooth edge alpha masks so glass
    /// seamlessly disappears into the webview over the fade zone.
    private func updateBlurMask() {
        let isLeft = (orientation == .left)
        let activeEdge: Double = isLeft ? 24.0 : (isRefractiveGlassEnabled ? Double(Self.refractiveEdgeHeight) : Double(Self.edgeHeight))
        let minExtent: Double = isLeft ? 68.0 : (isRefractiveGlassEnabled ? Double(Self.refractiveTotalHeight) : Double(Self.totalHeight))
        let rawExtent = isLeft ? bounds.width : bounds.height
        let extent = Double(max(Double(rawExtent), minExtent))
        builtForExtent = rawExtent
        builtForSize = bounds.size

        // Unified L-shape mode when Vertical tab rail is visible: ONE single glass surface covers
        // both the top toolbar (matching Compact layout's exact solid/fade profile) and the left rail (`0 ..< verticalRailWidth`).
        if !isLeft && verticalRailWidth > 0.5 && bounds.width > 1 && bounds.height > 1 {
            let w = Double(bounds.width)
            let h = Double(bounds.height)
            let topSolid = Double(topBarHeight) + (hasFixedHeader ? 2.5 : 0.0)
            let topFade = hasFixedHeader ? 0.0 : activeEdge
            let topTotal = topSolid + topFade
            let railW = Double(verticalRailWidth)
            let o = Double(Self.liquidGlassOverhang)
            let leftFade = 0.0

            let backdropMask = Self.makeLShapeAlphaMaskImage(
                width: w, height: h,
                topH: topTotal, railW: railW,
                topFade: topFade, leftFade: leftFade,
                offsetX: 0, offsetY: 0,
                canvasW: w, canvasH: h
            )
            let liquidMask = Self.makeLShapeAlphaMaskImage(
                width: w, height: h,
                topH: topTotal, railW: railW,
                topFade: topFade, leftFade: leftFade,
                offsetX: o, offsetY: 0,
                canvasW: w + o * 2.0, canvasH: h + o
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lShapeBackdropMaskLayer.frame = bounds
            lShapeBackdropMaskLayer.contents = backdropMask
            lShapeBackdropMaskLayer.contentsGravity = .resize
            lShapeTintMaskLayer.frame = bounds
            lShapeTintMaskLayer.contents = backdropMask
            lShapeTintMaskLayer.contentsGravity = .resize
            lShapeLiquidMaskLayer.frame = NSRect(origin: .zero, size: NSSize(width: bounds.width + Self.liquidGlassOverhang * 2, height: bounds.height + Self.liquidGlassOverhang))
            lShapeLiquidMaskLayer.contents = liquidMask
            lShapeLiquidMaskLayer.contentsGravity = .resize
            backdropLayer?.mask = lShapeBackdropMaskLayer
            liquidGlassView?.layer?.mask = lShapeLiquidMaskLayer
            tintLayer.mask = lShapeTintMaskLayer
            CATransaction.commit()

            if let backdrop = backdropLayer {
                if isRefractiveGlassEnabled {
                    if let lens = Self.makeLShapeRefractionMapImage(
                        width: w, height: h, topH: topTotal, railW: railW, topFade: topFade, leftFade: leftFade
                    ) {
                        backdrop.setValue(lens, forKeyPath: "filters.displacementMap.inputMaskImage")
                        backdrop.setValue(lens, forKeyPath: "filters.chromaticAberrationMap.inputMaskImage")
                    }
                    let blurRadius = hasFixedHeader ? appliedRefractiveFrost : max(appliedRefractiveFrost, 12.0)
                    if blurRadius > 0.05 {
                        let blurImg = (appliedRefractiveFrost > 0.05 || hasFixedHeader)
                            ? backdropMask
                            : Self.makeLShapeBottomFuzzyMaskImage(width: w, height: h, topH: topTotal, railW: railW)
                        if let blurImg {
                            backdrop.setValue(blurImg, forKeyPath: "filters.variableBlur.inputMaskImage")
                        }
                    }
                } else if let backdropMask {
                    backdrop.setValue(backdropMask, forKeyPath: "filters.variableBlur.inputMaskImage")
                }
            }
            return
        }

        // Standard top-only (Compact / Separate) mode: restore 1D gradient masks.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer?.mask = isRefractiveGlassEnabled ? backdropFadeMaskLayer : nil
        liquidGlassView?.layer?.mask = liquidGlassMaskLayer
        tintLayer.mask = nil
        CATransaction.commit()

        if isRefractiveGlassEnabled {
            var locs: [NSNumber] = []
            var maskColors: [CGColor] = []
            let solidEnd = max(0.0, extent - activeEdge)
            if !isLeft && hasFixedHeader {
                // Stop glass cleanly at `solidEnd` so ZERO pixels invade the fixed header below the toolbar.
                let seamLoc = min(1.0, solidEnd / extent)
                let afterLoc = min(1.0, (solidEnd + 0.5) / extent)
                locs = [0.0, NSNumber(value: seamLoc), NSNumber(value: afterLoc), 1.0]
                maskColors = [
                    NSColor.white.cgColor,
                    NSColor.white.cgColor,
                    NSColor.clear.cgColor,
                    NSColor.clear.cgColor
                ]
            } else {
                let stops = 24
                for i in 0..<stops {
                    let u = Double(i) / Double(stops - 1)
                    let pos = u * extent
                    let alpha: Double = (pos <= solidEnd) ? 1.0 : Self.quinticFalloff((pos - solidEnd) / max(1.0, activeEdge))
                    locs.append(NSNumber(value: u))
                    maskColors.append(NSColor.white.withAlphaComponent(CGFloat(alpha)).cgColor)
                }
            }

            let expandedSize = isLeft
                ? NSSize(width: bounds.width, height: bounds.height + Self.liquidGlassOverhang * 2)
                : NSSize(width: bounds.width + Self.liquidGlassOverhang * 2, height: bounds.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liquidGlassMaskLayer.frame = NSRect(origin: .zero, size: expandedSize)
            liquidGlassMaskLayer.locations = locs
            liquidGlassMaskLayer.colors = maskColors
            backdropFadeMaskLayer.frame = bounds
            backdropFadeMaskLayer.locations = locs
            backdropFadeMaskLayer.colors = maskColors
            if !isLeft, let reflBackdrop = fixedReflectionBackdropLayer {
                let seamY = max(1.0, extent - activeEdge)
                let bandH = min(34.0, seamY)
                let bandStart = max(0.0, seamY - bandH)
                var reflLocs: [NSNumber] = [0.0, NSNumber(value: bandStart / extent)]
                var reflColors: [CGColor] = [NSColor.clear.cgColor, NSColor.clear.cgColor]
                let rampSteps = 10
                for s in 1...rampSteps {
                    let frac = Double(s) / Double(rampSteps)
                    let yPos = bandStart + frac * bandH
                    // Smooth ease-in from 0 at top of reflection band to 1.0 right at the fixed bar seam
                    let eased = 1.0 - Self.quinticFalloff(frac)
                    reflLocs.append(NSNumber(value: min(1.0, yPos / extent)))
                    reflColors.append(NSColor.white.withAlphaComponent(CGFloat(eased)).cgColor)
                }
                let afterSeam = min(1.0, (seamY + 0.5) / extent)
                reflLocs.append(NSNumber(value: afterSeam))
                reflColors.append(NSColor.clear.cgColor)
                reflLocs.append(1.0)
                reflColors.append(NSColor.clear.cgColor)

                fixedReflectionContainerLayer.frame = bounds
                reflBackdrop.frame = bounds
                fixedReflectionMaskLayer.frame = bounds
                fixedReflectionMaskLayer.locations = reflLocs
                fixedReflectionMaskLayer.colors = reflColors
                if let reflMap = Self.makeFixedReflectionMapImage(viewHeight: extent, seamY: seamY) {
                    reflBackdrop.setValue(reflMap, forKeyPath: "filters.displacementMap.inputMaskImage")
                }
            }
            CATransaction.commit()
        }

        if let backdrop = backdropLayer {
            if isRefractiveGlassEnabled {
                if let lens = Self.makeRefractionMapImage(viewHeight: extent, edgeHeight: activeEdge, isLeftEdge: isLeft) {
                    backdrop.setValue(lens, forKeyPath: "filters.displacementMap.inputMaskImage")
                    backdrop.setValue(lens, forKeyPath: "filters.chromaticAberrationMap.inputMaskImage")
                }
                if appliedRefractiveFrost > 0.05,
                   let blurMask = Self.makeMaskImage(viewHeight: extent, edgeHeight: activeEdge, isLeftEdge: isLeft) {
                    backdrop.setValue(blurMask, forKeyPath: "filters.variableBlur.inputMaskImage")
                }
            } else if let mask = Self.makeMaskImage(
                viewHeight: extent,
                edgeHeight: hasFixedHeader ? 0.5 : activeEdge,
                solidEndOverride: hasFixedHeader ? max(0.0, extent - activeEdge) : nil,
                fadeEndOverride: hasFixedHeader ? max(0.5, extent - activeEdge + 0.5) : nil,
                isLeftEdge: isLeft
            ) {
                backdrop.setValue(mask, forKeyPath: "filters.variableBlur.inputMaskImage")
            }
        } else if let effect = fallbackEffectView {
            let maskLayer = CAGradientLayer()
            maskLayer.startPoint = isLeft ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 1)
            maskLayer.endPoint = isLeft ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 0)
            let stops = 12
            maskLayer.locations = (0..<stops).map { NSNumber(value: Double($0) / Double(stops - 1)) }
            maskLayer.colors = (0..<stops).map {
                NSColor.white.withAlphaComponent(CGFloat(Self.profile(atY: Double($0) / Double(stops - 1) * extent, viewHeight: extent))).cgColor
            }
            maskLayer.frame = effect.bounds
            effect.layer?.mask = maskLayer
        }
    }

    static func makeRefractionMapImage(viewHeight h: Double, edgeHeight edge: Double = Double(refractiveEdgeHeight), solidEndOverride: Double? = nil, fadeEndOverride: Double? = nil, rows: Int = 128, isLeftEdge: Bool = false) -> CGImage? {
        let cols = 128
        let fadeEnd = fadeEndOverride ?? h
        let solidEnd = solidEndOverride ?? max(1.0, fadeEnd - edge)
        let fadeSpan = max(1.0, fadeEnd - solidEnd)
        var pixels = [UInt8](repeating: 128, count: rows * cols * 4)
        for row in 0..<rows {
            for col in 0..<cols {
                let primaryFrac = isLeftEdge ? (Double(col) / Double(cols - 1)) : (Double(row) / Double(rows - 1))
                let crossFrac = isLeftEdge ? (Double(row) / Double(rows - 1)) : (Double(col) / Double(cols - 1))
                let pos = primaryFrac * h
                let fade: Double
                if pos <= solidEnd {
                    fade = 1.0
                } else if pos >= fadeEnd {
                    fade = 0.0
                } else {
                    fade = quinticFalloff((pos - solidEnd) / fadeSpan)
                }
                let t = min(1.0, max(0.0, pos / solidEnd))
                let basePrimary = (cos(t * .pi) * refractiveVerticalCurve + sin(t * .pi * 2.0) * 0.22) * fade
                let edgeCross = sin(crossFrac * .pi)
                let nCross = max(-1.0, min(1.0, sin(crossFrac * .pi * refractiveRippleFrequency + t * .pi) * refractiveRippleStrength * edgeCross * fade))
                let nPrimary = max(-1.0, min(1.0, basePrimary + cos(crossFrac * .pi * 4.0) * (refractiveRippleStrength * 0.3) * edgeCross * fade))
                let nx = isLeftEdge ? nPrimary : nCross
                let ny = isLeftEdge ? nCross : nPrimary
                let idx = (row * cols + col) * 4
                pixels[idx] = UInt8(max(0, min(255, Int((128.0 + nx * 127.0).rounded()))))
                pixels[idx + 1] = UInt8(max(0, min(255, Int((128.0 + ny * 127.0).rounded()))))
                pixels[idx + 2] = 128
                pixels[idx + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Maximum downward sample shift (in points) for reflecting a docked fixed header upward into the toolbar.
    static let fixedReflectionMaxShift: Double = 72.0

    /// Generates a 1×128 vertical displacement map that reflects pixels from below `seamY` (the docked fixed header)
    /// upward onto the bottom edge of the toolbar (`y < seamY`). In WindowServer top-left texture space, `+Y` shifts downward.
    static func makeFixedReflectionMapImage(viewHeight h: Double, seamY: Double, rows: Int = 128) -> CGImage? {
        var pixels = [UInt8](repeating: 128, count: rows * 4)
        let maxBelow = max(4.0, h - seamY - 4.0)
        for row in 0..<rows {
            let y = Double(row) / Double(rows - 1) * h
            var ny = 0.0
            if y < seamY {
                let d = seamY - y
                // Mirror y = seamY - d -> sample at seamY + min(d, maxBelow), so downward shift = d + min(d, maxBelow)
                let shiftDown = min(fixedReflectionMaxShift, d + min(d, maxBelow))
                ny = shiftDown / fixedReflectionMaxShift
            }
            pixels[row * 4] = 128
            pixels[row * 4 + 1] = UInt8(max(0, min(255, Int((128.0 + ny * 127.0).rounded()))))
            pixels[row * 4 + 2] = 128
            pixels[row * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeLShapeAlphaMaskImage(
        width w: Double, height h: Double,
        topH: Double, railW: Double,
        topFade: Double, leftFade: Double,
        offsetX: Double, offsetY: Double,
        canvasW: Double, canvasH: Double,
        dim: Int = 512
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        let topSolid = max(0.0, topH - topFade)
        let leftSolid = max(0.0, railW - leftFade)
        for row in 0..<dim {
            let cy = (Double(row) + 0.5) / Double(dim) * canvasH
            let y = cy - offsetY
            let aTop: Double
            if y < 0 || y >= topH {
                aTop = (y < 0) ? 1.0 : 0.0
            } else if topFade <= 0.5 || y <= topSolid {
                aTop = 1.0
            } else {
                aTop = quinticFalloff((y - topSolid) / topFade)
            }
            for col in 0..<dim {
                let cx = (Double(col) + 0.5) / Double(dim) * canvasW
                let x = cx - offsetX
                let aLeft: Double
                if x < 0 || x >= railW {
                    aLeft = (x < 0) ? 1.0 : 0.0
                } else if leftFade <= 0.5 || x <= leftSolid {
                    aLeft = 1.0
                } else {
                    aLeft = quinticFalloff((x - leftSolid) / leftFade)
                }
                let a = (y > h) ? 0.0 : max(aTop, aLeft)
                let v = UInt8(max(0, min(255, Int((a * 255.0).rounded()))))
                let idx = (row * dim + col) * 4
                pixels[idx] = v
                pixels[idx + 1] = v
                pixels[idx + 2] = v
                pixels[idx + 3] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: dim, height: dim, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dim * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeLShapeRefractionMapImage(
        width w: Double, height h: Double,
        topH: Double, railW: Double,
        topFade: Double, leftFade: Double,
        dim: Int = 512
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 128, count: dim * dim * 4)
        let topSolid = max(1.0, topH - topFade)
        let leftSolid = max(1.0, railW - leftFade)
        for row in 0..<dim {
            let y = (Double(row) + 0.5) / Double(dim) * h
            let fTop: Double = (y >= topH) ? 0.0 : ((topFade <= 0.5 || y <= topSolid) ? 1.0 : quinticFalloff((y - topSolid) / topFade))
            let ty = min(1.0, max(0.0, y / topSolid))
            let baseY = (cos(ty * .pi) * refractiveVerticalCurve + sin(ty * .pi * 2.0) * 0.22) * fTop
            let vNorm = Double(row) / Double(dim - 1)
            let edgeY = sin(vNorm * .pi)
            for col in 0..<dim {
                let x = (Double(col) + 0.5) / Double(dim) * w
                let fLeft: Double = (x >= railW) ? 0.0 : ((leftFade <= 0.5 || x <= leftSolid) ? 1.0 : quinticFalloff((x - leftSolid) / leftFade))
                if fTop <= 0.001 && fLeft <= 0.001 {
                    let idx = (row * dim + col) * 4
                    pixels[idx] = 128; pixels[idx + 1] = 128; pixels[idx + 2] = 128; pixels[idx + 3] = 255
                    continue
                }
                let uNorm = Double(col) / Double(dim - 1)
                let edgeX = sin(uNorm * .pi)
                let tx = min(1.0, max(0.0, x / leftSolid))
                let baseX = (cos(tx * .pi) * refractiveVerticalCurve + sin(tx * .pi * 2.0) * 0.22) * fLeft
                let nxTop = sin(uNorm * .pi * refractiveRippleFrequency + ty * .pi) * refractiveRippleStrength * edgeX * fTop
                let nyTop = baseY + cos(uNorm * .pi * 4.0) * (refractiveRippleStrength * 0.3) * edgeX * fTop
                let nxLeft = baseX + cos(vNorm * .pi * 4.0) * (refractiveRippleStrength * 0.3) * edgeY * fLeft
                let nyLeft = sin(vNorm * .pi * refractiveRippleFrequency + tx * .pi) * refractiveRippleStrength * edgeY * fLeft
                let nx = max(-1.0, min(1.0, nxTop + nxLeft))
                let ny = max(-1.0, min(1.0, nyTop + nyLeft))
                let idx = (row * dim + col) * 4
                pixels[idx] = UInt8(max(0, min(255, Int((128.0 + nx * 127.0).rounded()))))
                pixels[idx + 1] = UInt8(max(0, min(255, Int((128.0 + ny * 127.0).rounded()))))
                pixels[idx + 2] = 128
                pixels[idx + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: dim, height: dim, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dim * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 1D vertical mask for non-fixed pages: keeps the upper toolbar crystal-clear refractive glass and
    /// applies a soft fuzzy frosted blur band along the bottom edge fading smoothly to 0 into the page.
    static func makeBottomFuzzyBlurMaskImage(viewHeight h: Double, edgeHeight edge: Double, rows: Int = 128) -> CGImage? {
        let solidEnd = max(0.0, h - edge)
        let rampInStart = max(0.0, solidEnd - 18.0)
        var pixels = [UInt8](repeating: 0, count: rows * 4)
        for i in 0..<rows {
            let y = Double(i) / Double(rows - 1) * h
            let p: Double
            if y < rampInStart {
                p = 0.0
            } else if y <= solidEnd {
                p = 1.0 - quinticFalloff((y - rampInStart) / max(1.0, solidEnd - rampInStart))
            } else {
                p = quinticFalloff((y - solidEnd) / max(1.0, edge))
            }
            let v = UInt8(max(0, min(255, Int((p * 255.0).rounded()))))
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v; pixels[i * 4 + 3] = v
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 2D L-shape fuzzy bottom/right edge blur mask for Vertical tab layout on non-fixed pages.
    static func makeLShapeBottomFuzzyMaskImage(width w: Double, height h: Double, topH: Double, railW: Double, dim: Int = 256) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        let topStart = max(0.0, topH - 22.0)
        let topPeak = max(0.0, topH - 8.0)
        let leftStart = max(0.0, railW - 14.0)
        let leftPeak = max(0.0, railW - 5.0)
        for row in 0..<dim {
            let y = (Double(row) + 0.5) / Double(dim) * h
            let bTop: Double
            if y < topStart || y >= topH { bTop = 0.0 }
            else if y <= topPeak { bTop = 1.0 - quinticFalloff((y - topStart) / max(1.0, topPeak - topStart)) }
            else { bTop = quinticFalloff((y - topPeak) / max(1.0, topH - topPeak)) }
            for col in 0..<dim {
                let x = (Double(col) + 0.5) / Double(dim) * w
                let bLeft: Double
                if x < leftStart || x >= railW { bLeft = 0.0 }
                else if x <= leftPeak { bLeft = 1.0 - quinticFalloff((x - leftStart) / max(1.0, leftPeak - leftStart)) }
                else { bLeft = quinticFalloff((x - leftPeak) / max(1.0, railW - leftPeak)) }
                let p = max(bTop, bLeft)
                let v = UInt8(max(0, min(255, Int((p * 255.0).rounded()))))
                let idx = (row * dim + col) * 4
                pixels[idx] = v; pixels[idx + 1] = v; pixels[idx + 2] = v; pixels[idx + 3] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: dim, height: dim, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dim * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeMaskImage(viewHeight h: Double, edgeHeight edge: Double = Double(edgeHeight), solidEndOverride: Double? = nil, fadeEndOverride: Double? = nil, rows: Int = 128, isLeftEdge: Bool = false) -> CGImage? {
        let fadeEnd = fadeEndOverride ?? h
        let solidEnd = solidEndOverride ?? max(0.0, fadeEnd - edge)
        let fadeSpan = max(1.0, fadeEnd - solidEnd)
        var pixels = [UInt8](repeating: 0, count: rows * 4)
        for i in 0..<rows {
            let pos = Double(i) / Double(rows - 1) * h
            let p: Double
            if pos <= solidEnd {
                p = 1.0
            } else if pos >= fadeEnd {
                p = 0.0
            } else {
                p = quinticFalloff((pos - solidEnd) / fadeSpan)
            }
            let v = UInt8((p * 255).rounded())
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = v
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let width = isLeftEdge ? rows : 1
        let height = isLeftEdge ? 1 : rows
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private final class PassthroughReflectionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
