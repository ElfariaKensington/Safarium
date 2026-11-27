import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import QuartzCore

// MARK: - Injectable Biometric Evaluator Protocol (Production Hardware + Hermetic Testing)

enum BiometricEvaluationOutcome: Equatable {
    case matched
    case cancelled
    case failed(message: String)
    case fallbackRequested
    case unavailable(message: String)
}

protocol BiometricAuthEvaluating: AnyObject {
    /// True when Touch ID or Apple Watch companion authentication is enrolled and available.
    var canEvaluateBiometricsOrWatch: Bool { get }
    /// True when device owner authentication (biometrics, Watch, or macOS password) is available.
    var canEvaluateDeviceOwnerAuth: Bool { get }
    /// Optional embedded `LAAuthenticationView` bound to the active `LAContext` when hardware biometrics are live.
    func makeEmbeddedAuthView(controlSize: NSControl.ControlSize) -> NSView?
    /// Evaluates inline biometric/Watch policy (or device owner policy when `allowPasswordFallback` is true).
    func evaluate(reason: String, allowPasswordFallback: Bool, completion: @escaping (BiometricEvaluationOutcome) -> Void)
    /// Cancels any in-flight `LAContext` evaluation immediately.
    func invalidate()
}

final class SystemBiometricAuthenticator: BiometricAuthEvaluating {
    /// Context paired with the on-screen `LAAuthenticationView`. It must survive failed/cancelled scans:
    /// evaluating any other context shows the system Touch ID alert instead of the inline glyph.
    private var embeddedContext: LAContext?
    private var embeddedView: NSView?
    /// Unbound context for the macOS password fallback (system sheet, like Safari's "Use Password…").
    private var passwordContext: LAContext?

    var canEvaluateBiometricsOrWatch: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: &err)
    }

    var canEvaluateDeviceOwnerAuth: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    /// Returns the live Touch ID glyph view bound to this authenticator's context. Repeated calls return the
    /// same view until the context becomes unusable, then a fresh context/view pair (callers re-attach it).
    func makeEmbeddedAuthView(controlSize: NSControl.ControlSize = .regular) -> NSView? {
        if let embeddedView, embeddedContext != nil {
            return embeddedView
        }
        guard canEvaluateBiometricsOrWatch else { return nil }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password…"
        let view = LAAuthenticationView(context: ctx, controlSize: controlSize)
        embeddedContext = ctx
        embeddedView = view
        return view
    }

    func evaluate(
        reason: String,
        allowPasswordFallback: Bool,
        completion: @escaping (BiometricEvaluationOutcome) -> Void
    ) {
        let usePassword = allowPasswordFallback || !canEvaluateBiometricsOrWatch
        let ctx: LAContext
        let policy: LAPolicy
        if usePassword {
            passwordContext?.invalidate()
            let fresh = LAContext()
            fresh.localizedCancelTitle = "Cancel"
            passwordContext = fresh
            ctx = fresh
            policy = .deviceOwnerAuthentication
        } else {
            if embeddedContext == nil {
                // No glyph view was requested (headless path): evaluate a standalone context (system alert).
                embeddedContext = LAContext()
            }
            ctx = embeddedContext!
            policy = .deviceOwnerAuthenticationWithBiometricsOrCompanion
        }

        var canErr: NSError?
        guard ctx.canEvaluatePolicy(policy, error: &canErr) else {
            let msg = canErr?.localizedDescription ?? "Touch ID is not available on this Mac."
            if !usePassword { dropEmbeddedContext() }
            DispatchQueue.main.async { completion(.unavailable(message: msg)) }
            return
        }

        ctx.evaluatePolicy(policy, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    completion(.matched)
                    return
                }
                let nsErr = error as NSError?
                let code = (nsErr?.domain == LAError.errorDomain) ? nsErr.flatMap { LAError.Code(rawValue: $0.code) } : nil
                switch code {
                case .userCancel?, .appCancel?, .systemCancel?:
                    completion(.cancelled)
                case .userFallback?:
                    completion(.fallbackRequested)
                case .biometryNotAvailable?, .biometryNotEnrolled?, .biometryLockout?, .passcodeNotSet?:
                    if !usePassword { self.dropEmbeddedContext() }
                    completion(.unavailable(message: nsErr?.localizedDescription ?? "Touch ID is unavailable."))
                case .invalidContext?, .notInteractive?:
                    if !usePassword { self.dropEmbeddedContext() }
                    completion(.cancelled)
                default:
                    completion(.failed(message: nsErr?.localizedDescription ?? "Touch ID did not recognize your fingerprint."))
                }
            }
        }
    }

    private func dropEmbeddedContext() {
        embeddedContext?.invalidate()
        embeddedContext = nil
        embeddedView = nil
    }

    func invalidate() {
        dropEmbeddedContext()
        passwordContext?.invalidate()
        passwordContext = nil
    }
}

// MARK: - Safari Native Coral Touch ID Biometric Scanner Widget (`SafariBiometricScannerView`)

/// Renders Safari's signature coral-pink (`#FF5A6E`) Touch ID biometric scanner glyph paired with
/// macOS's native `LAAuthenticationView` (`LocalAuthenticationEmbeddedUI`) and interactive status caption.
final class SafariBiometricScannerView: NSView {
    enum State: Equatable {
        case idle
        case scanning
        case matched
        case failed(String)
        case fallbackPassword
    }

    static let coralPink = NSColor(srgbRed: 1.0, green: 0.392, blue: 0.459, alpha: 1.0) // #FF6475 Safari Touch ID coral
    static let matchedGreen = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)

    var defaultPromptText: String = "Continue with Touch ID" {
        didSet { syncCaptionText() }
    }

    /// Invoked when the user clicks the scanner icon or presses Space/Return to retry Touch ID or use password.
    var onActivateScanner: (() -> Void)?

    private(set) var state: State = .idle
    static let stageSide: CGFloat = 48
    private let iconStage = NSView()
    private let embeddedScaleHost = EmbeddedAuthScaleHost()
    private let vectorGlyphView = TouchIDVectorGlyphView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
    private var embeddedLAView: NSView?
    private let captionLabel = NSTextField(labelWithString: "Continue with Touch ID")
    private var pulseTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pulseTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { true }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        iconStage.translatesAutoresizingMaskIntoConstraints = false
        iconStage.wantsLayer = true
        addSubview(iconStage)

        vectorGlyphView.translatesAutoresizingMaskIntoConstraints = false
        iconStage.addSubview(vectorGlyphView)

        embeddedScaleHost.translatesAutoresizingMaskIntoConstraints = false
        embeddedScaleHost.isHidden = true
        iconStage.addSubview(embeddedScaleHost)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            iconStage.topAnchor.constraint(equalTo: topAnchor),
            iconStage.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconStage.widthAnchor.constraint(equalToConstant: Self.stageSide),
            iconStage.heightAnchor.constraint(equalToConstant: Self.stageSide),

            embeddedScaleHost.leadingAnchor.constraint(equalTo: iconStage.leadingAnchor),
            embeddedScaleHost.trailingAnchor.constraint(equalTo: iconStage.trailingAnchor),
            embeddedScaleHost.topAnchor.constraint(equalTo: iconStage.topAnchor),
            embeddedScaleHost.bottomAnchor.constraint(equalTo: iconStage.bottomAnchor),

            vectorGlyphView.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
            vectorGlyphView.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
            vectorGlyphView.widthAnchor.constraint(equalToConstant: 42),
            vectorGlyphView.heightAnchor.constraint(equalToConstant: 42),

            captionLabel.topAnchor.constraint(equalTo: iconStage.bottomAnchor, constant: 10),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(defaultPromptText)
    }

    /// Hosts the live `LAAuthenticationView` (Apple's own Touch ID glyph, drawn in-process with
    /// CAShapeLayers). It only ships at 16/32/64/128 pt, so the 64 pt `.regular` view is scaled into the
    /// 48 pt stage Safari uses. The vector glyph is only a fallback for Macs without Touch ID/Watch.
    func attachEmbeddedAuthenticationView(_ view: NSView?) {
        if let view, view === embeddedLAView { return }
        embeddedLAView?.removeFromSuperview()
        embeddedLAView = view
        guard let view else {
            embeddedScaleHost.isHidden = true
            syncEmbeddedVisibility()
            return
        }
        var natural = view.fittingSize
        if natural.width < 1 || natural.height < 1 { natural = view.frame.size }
        if natural.width < 1 || natural.height < 1 { natural = CGSize(width: Self.stageSide, height: Self.stageSide) }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: natural)
        embeddedScaleHost.scale = Self.stageSide / max(natural.width, natural.height)
        embeddedScaleHost.addSubview(view)
        embeddedScaleHost.isHidden = false
        embeddedScaleHost.needsLayout = true
        syncEmbeddedVisibility()
    }

    private func syncEmbeddedVisibility() {
        // Apple's view renders every state itself (idle, scanning, mismatch, success checkmark), so never
        // draw the vector glyph on top of it.
        let hasLive = embeddedLAView != nil
        embeddedScaleHost.isHidden = !hasLive
        vectorGlyphView.isHidden = hasLive
    }

    /// Ensures the coral vector Touch ID ridges are visible during AppKit offscreen `cacheDisplay`
    /// bitmap captures (where WindowServer `CALayerHost` out-of-process surfaces do not draw).
    func withVectorGlyphVisibleForSnapshot<T>(_ body: () -> T) -> T {
        let wasHidden = vectorGlyphView.isHidden
        vectorGlyphView.isHidden = false
        defer { vectorGlyphView.isHidden = wasHidden }
        return body()
    }

    func setState(_ newState: State, animated: Bool = true) {
        state = newState
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = animated && !reduceMotion

        switch newState {
        case .idle:
            vectorGlyphView.setVisualMode(.fingerprint, strokeColor: Self.coralPink, animated: shouldAnimate)
            vectorGlyphView.setScanningPulse(false)
        case .scanning:
            vectorGlyphView.setVisualMode(.fingerprint, strokeColor: Self.coralPink, animated: shouldAnimate)
            vectorGlyphView.setScanningPulse(shouldAnimate)
        case .matched:
            vectorGlyphView.setVisualMode(.checkmark, strokeColor: Self.matchedGreen, animated: shouldAnimate)
            vectorGlyphView.setScanningPulse(false)
        case .failed:
            vectorGlyphView.setScanningPulse(false)
            vectorGlyphView.setVisualMode(.fingerprint, strokeColor: Self.coralPink, animated: false)
            if shouldAnimate {
                playHorizontalShake()
            }
        case .fallbackPassword:
            vectorGlyphView.setScanningPulse(false)
            vectorGlyphView.setVisualMode(.fingerprint, strokeColor: Self.coralPink, animated: shouldAnimate)
        }
        syncEmbeddedVisibility()
        syncCaptionText()
    }

    private func syncCaptionText() {
        switch state {
        case .idle, .scanning:
            captionLabel.stringValue = defaultPromptText
            captionLabel.textColor = .labelColor
        case .matched:
            captionLabel.stringValue = "Authenticated"
            captionLabel.textColor = .secondaryLabelColor
        case .failed:
            captionLabel.stringValue = "Try Touch ID Again or Click to Use Password"
            captionLabel.textColor = .secondaryLabelColor
        case .fallbackPassword:
            captionLabel.stringValue = "Click to Authenticate with Password"
            captionLabel.textColor = .systemBlue
        }
        setAccessibilityLabel(captionLabel.stringValue)
    }

    private func playHorizontalShake() {
        guard let layer = iconStage.layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -9, 9, -7, 7, -4, 4, 0]
        anim.keyTimes = [0, 0.14, 0.28, 0.44, 0.60, 0.75, 0.88, 1.0]
        anim.duration = 0.38
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "safariBiometricShake")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        alphaValue = 0.90
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        alphaValue = 1.0
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.74
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = isHovered ? 0.90 : 1.0
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -6, dy: -6).contains(pt) {
            onActivateScanner?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
            onActivateScanner?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivateScanner?()
        return true
    }
}

/// Scales its subviews with `sublayerTransform` (re-applied on every layout/display pass because AppKit owns
/// the hosted view's own layer transform and resets it).
private final class EmbeddedAuthScaleHost: NSView {
    var scale: CGFloat = 1 {
        didSet { applyScale() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyScale() }
    override func layout() {
        super.layout()
        applyScale()
    }

    private func applyScale() {
        layer?.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the scanner (retry / password)
}

// MARK: - Precision CoreAnimation Coral Touch ID Vector Fingerprint + Checkmark Glyph

private final class TouchIDVectorGlyphView: NSView {
    enum VisualMode {
        case fingerprint
        case checkmark
    }

    private var ridgeLayers: [CAShapeLayer] = []
    private let checkCircleLayer = CAShapeLayer()
    private let checkMarkLayer = CAShapeLayer()
    private var currentMode: VisualMode = .fingerprint
    private var strokeColor: NSColor = SafariBiometricScannerView.coralPink

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func buildLayers() {
        guard let root = layer else { return }
        let paths = Self.makeFingerprintRidgePaths(in: CGSize(width: 42, height: 42))
        for path in paths {
            let sl = CAShapeLayer()
            sl.path = path
            sl.fillColor = nil
            sl.strokeColor = strokeColor.cgColor
            sl.lineWidth = 1.38
            sl.lineCap = .round
            sl.lineJoin = .round
            root.addSublayer(sl)
            ridgeLayers.append(sl)
        }

        // Circular clip mask so outer ridges form Safari's exact circular Touch ID silhouette
        let maskLayer = CAShapeLayer()
        let clipPath = CGPath(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 39, height: 39), transform: nil)
        maskLayer.path = clipPath
        root.mask = maskLayer

        // Checkmark overlay for `.matched`
        checkCircleLayer.path = CGPath(ellipseIn: CGRect(x: 3, y: 3, width: 36, height: 36), transform: nil)
        checkCircleLayer.fillColor = SafariBiometricScannerView.matchedGreen.withAlphaComponent(0.14).cgColor
        checkCircleLayer.strokeColor = SafariBiometricScannerView.matchedGreen.cgColor
        checkCircleLayer.lineWidth = 2.0
        checkCircleLayer.opacity = 0
        checkCircleLayer.isHidden = true
        root.addSublayer(checkCircleLayer)

        let checkPath = CGMutablePath()
        checkPath.move(to: CGPoint(x: 13.5, y: 21.5))
        checkPath.addLine(to: CGPoint(x: 18.8, y: 26.8))
        checkPath.addLine(to: CGPoint(x: 29.0, y: 15.8))
        checkMarkLayer.path = checkPath
        checkMarkLayer.fillColor = nil
        checkMarkLayer.strokeColor = SafariBiometricScannerView.matchedGreen.cgColor
        checkMarkLayer.lineWidth = 2.6
        checkMarkLayer.lineCap = .round
        checkMarkLayer.lineJoin = .round
        checkMarkLayer.opacity = 0
        checkMarkLayer.isHidden = true
        root.addSublayer(checkMarkLayer)
    }

    func setVisualMode(_ mode: VisualMode, strokeColor: NSColor, animated: Bool) {
        self.currentMode = mode
        self.strokeColor = strokeColor

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.20)

        let showFingerprint = (mode == .fingerprint)
        for sl in ridgeLayers {
            sl.removeAnimation(forKey: "ridgeShimmer")
            sl.removeAnimation(forKey: "opacity")
            sl.strokeColor = strokeColor.cgColor
            sl.opacity = showFingerprint ? 1.0 : 0.0
            sl.isHidden = !showFingerprint
        }
        checkCircleLayer.isHidden = showFingerprint
        checkMarkLayer.isHidden = showFingerprint
        checkCircleLayer.opacity = showFingerprint ? 0.0 : 1.0
        checkMarkLayer.opacity = showFingerprint ? 0.0 : 1.0

        if !showFingerprint && animated {
            let strokeAnim = CABasicAnimation(keyPath: "strokeEnd")
            strokeAnim.fromValue = 0.0
            strokeAnim.toValue = 1.0
            strokeAnim.duration = 0.22
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            checkMarkLayer.add(strokeAnim, forKey: "checkDraw")
        }
        CATransaction.commit()
    }

    func setScanningPulse(_ active: Bool) {
        guard let root = layer else { return }
        root.removeAnimation(forKey: "touchIDPulse")
        for (idx, sl) in ridgeLayers.enumerated() {
            sl.removeAnimation(forKey: "ridgeShimmer")
            if active {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1.0
                anim.toValue = 0.58
                anim.duration = 0.95
                anim.beginTime = CACurrentMediaTime() + Double(idx % 4) * 0.12
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sl.add(anim, forKey: "ridgeShimmer")
            } else if currentMode == .fingerprint {
                sl.opacity = 1.0
            }
        }
    }

    /// Generates strictly concentric, non-intersecting fingerprint arches & stems matching Apple's Touch ID icon in a 42×42 flipped canvas.
    private static func makeFingerprintRidgePaths(in size: CGSize) -> [CGPath] {
        let cx = size.width * 0.5   // 21.0
        let cy = size.height * 0.49 // 20.58
        var paths: [CGPath] = []

        func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180.0 }

        func addArch(radius r: CGFloat, startDeg: CGFloat, endDeg: CGFloat) {
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(startDeg), endAngle: deg(endDeg), clockwise: false)
            paths.append(p)
        }

        // Ring 1 (outermost r = 18.0)
        addArch(radius: 18.0, startDeg: 206, endDeg: 334)
        addArch(radius: 18.0, startDeg: 150, endDeg: 192)
        addArch(radius: 18.0, startDeg: 348, endDeg: 32)

        // Ring 2 (r = 15.0, split on upper-left & lower-right like SF Symbols `touchid`)
        addArch(radius: 15.0, startDeg: 196, endDeg: 356)
        addArch(radius: 15.0, startDeg: 132, endDeg: 182)
        addArch(radius: 15.0, startDeg: 10, endDeg: 52)

        // Ring 3 (r = 12.0, full top arch + parallel downward legs curving gently left)
        do {
            let r: CGFloat = 12.0
            let pL = CGMutablePath()
            pL.move(to: CGPoint(x: cx - r - 1.6, y: cy + 12.5))
            pL.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r - 0.2, y: cy + 6.5))
            pL.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(180), endAngle: deg(322), clockwise: false)
            paths.append(pL)

            let pR = CGMutablePath()
            pR.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(338), endAngle: deg(360), clockwise: false)
            pR.addQuadCurve(to: CGPoint(x: cx + r - 2.2, y: cy + 14.2), control: CGPoint(x: cx + r, y: cy + 7.5))
            paths.append(pR)
        }

        // Ring 4 (r = 9.0, continuous top arch + left & broken right leg)
        do {
            let r: CGFloat = 9.0
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - r - 1.5, y: cy + 15.5))
            p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r - 0.1, y: cy + 8.0))
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(180), endAngle: deg(360), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: cx + r - 1.0, y: cy + 7.0), control: CGPoint(x: cx + r, y: cy + 3.6))
            paths.append(p)

            let pRLow = CGMutablePath()
            pRLow.move(to: CGPoint(x: cx + r - 1.6, y: cy + 10.2))
            pRLow.addQuadCurve(to: CGPoint(x: cx + r - 3.2, y: cy + 17.5), control: CGPoint(x: cx + r - 2.2, y: cy + 14.0))
            paths.append(pRLow)
        }

        // Ring 5 (r = 6.0, inner hairpin loop)
        do {
            let r: CGFloat = 6.0
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - r - 1.4, y: cy + 17.8))
            p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r - 0.1, y: cy + 9.2))
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(180), endAngle: deg(360), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: cx + r - 2.4, y: cy + 18.6), control: CGPoint(x: cx + r - 0.2, y: cy + 10.0))
            paths.append(p)
        }

        // Ring 6 (r = 3.0, tight core loop + center ridge)
        do {
            let r: CGFloat = 3.0
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - r - 0.6, y: cy + 9.4))
            p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r, y: cy + 4.8))
            p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: deg(180), endAngle: deg(360), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: cx + r - 1.8, y: cy + 19.2), control: CGPoint(x: cx + r - 0.1, y: cy + 10.2))
            paths.append(p)

            let pCore = CGMutablePath()
            pCore.move(to: CGPoint(x: cx, y: cy + 0.5))
            pCore.addQuadCurve(to: CGPoint(x: cx - 1.8, y: cy + 19.2), control: CGPoint(x: cx - 0.2, y: cy + 10.2))
            paths.append(pCore)
        }

        return paths
    }
}
