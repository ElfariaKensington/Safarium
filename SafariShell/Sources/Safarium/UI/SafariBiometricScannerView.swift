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

// MARK: - Safari Native Biometric Sheet Models & Controller (`SafariBiometricSheetController`)

struct SafariBiometricAccountOption: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let initials: String

    static func computeInitials(from fullNameOrEmail: String) -> String {
        let trimmed = fullNameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "AA" }
        let base = trimmed.contains("@") ? String(trimmed.split(separator: "@").first ?? Substring(trimmed)) : trimmed
        let parts = base
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        if parts.count >= 2,
           let first = parts.first?.first,
           let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        let letters = base.filter { $0.isLetter || $0.isNumber }
        if letters.count >= 2 {
            return String(letters.prefix(2)).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }
}

enum SafariBiometricSheetKind {
    struct SignInWithAppleConfig {
        var siteDisplayName: String
        var siteHost: String
        var siteIcon: NSImage?
        var accountName: String
        var accountSubtitle: String
        var requestsEmailScope: Bool
        var hideMyEmailSelected: Bool
    }

    struct PasskeySignInConfig {
        var rpDisplayName: String
        var rpId: String
        var siteIcon: NSImage?
        var accounts: [SafariBiometricAccountOption]
        var selectedAccountIndex: Int
    }

    struct PasskeyCreateConfig {
        var rpDisplayName: String
        var rpId: String
        var siteIcon: NSImage?
        var account: SafariBiometricAccountOption
    }

    struct PasswordAutoFillConfig {
        var siteDisplayName: String
        var siteHost: String
        var siteIcon: NSImage?
        var account: SafariBiometricAccountOption
    }

    case signInWithApple(SignInWithAppleConfig)
    case passkeySignIn(PasskeySignInConfig)
    case passkeyCreate(PasskeyCreateConfig)
    case passwordAutoFill(PasswordAutoFillConfig)
}

/// Presents Safari's centered modal biometric authentication sheet over the active tab's content stage,
/// matching macOS Safari's "Sign in with Apple" & Passkey Touch ID modal sheet pixel-for-pixel.
final class SafariBiometricSheetView: NSView {
    // Callbacks
    var onCancel: (() -> Void)?
    var onSecondaryAction: (() -> Void)?
    var onSelectAccountIndex: ((Int) -> Void)?
    var onEmailPrivacyChanged: ((Bool) -> Void)?
    var onActivateBiometricScanner: (() -> Void)?

    let scannerView = SafariBiometricScannerView()

    private let backdropSnapshotView = NSImageView()
    private let scrimView = NSView()
    private let cardContainer = NSView()
    private let headerTitleLabel = NSTextField(labelWithString: "Sign in with Apple")
    private let cancelPillButton = SafariSheetCancelPillButton(title: "Cancel")
    private let bodyContentContainer = NSView()
    private let interactiveWebContainer = NSView()
    private var interactiveWebHeightConstraint: NSLayoutConstraint?

    private let appIconTile = SafariSquircleAppIconView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let accountsStack = NSStackView()
    private let emailScopeStack = NSStackView()
    private let separatorLine = NSView()
    private var separatorTopToAccountsConstraint: NSLayoutConstraint?
    private var separatorTopToEmailConstraint: NSLayoutConstraint?
    private let secondaryLinkButton = SafariBlueLinkButton(title: "Use a different Apple Account")

    private var kind: SafariBiometricSheetKind
    private var selectedAccountIndex: Int = 0
    private var hideMyEmail: Bool = false
    private(set) var isShowingInteractiveWebAuth: Bool = false

    init(kind: SafariBiometricSheetKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
        setupHierarchy()
        applyConfiguration(kind)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backdropSnapshotView.translatesAutoresizingMaskIntoConstraints = false
        backdropSnapshotView.wantsLayer = true
        backdropSnapshotView.imageScaling = .scaleAxesIndependently
        backdropSnapshotView.isHidden = true
        addSubview(backdropSnapshotView)

        // Dimmed Safari backdrop scrim (`rgba(0,0,0,0.36)`)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.36).cgColor
        addSubview(scrimView)

        // Centered 440pt continuous-corner (`22pt`) Safari modal sheet
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.wantsLayer = true
        cardContainer.layer?.cornerRadius = 22.0
        cardContainer.layer?.cornerCurve = .continuous
        cardContainer.layer?.shadowColor = NSColor.black.cgColor
        cardContainer.layer?.shadowOpacity = 0.24
        cardContainer.layer?.shadowRadius = 28.0
        cardContainer.layer?.shadowOffset = CGSize(width: 0, height: -10)
        addSubview(cardContainer)

        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.lineBreakMode = .byTruncatingTail
        cardContainer.addSubview(headerTitleLabel)

        cancelPillButton.translatesAutoresizingMaskIntoConstraints = false
        cancelPillButton.onClick = { [weak self] in
            self?.onCancel?()
        }
        cardContainer.addSubview(cancelPillButton)

        bodyContentContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(bodyContentContainer)

        interactiveWebContainer.translatesAutoresizingMaskIntoConstraints = false
        interactiveWebContainer.wantsLayer = true
        interactiveWebContainer.layer?.cornerRadius = 12.0
        interactiveWebContainer.layer?.cornerCurve = .continuous
        interactiveWebContainer.layer?.masksToBounds = true
        interactiveWebContainer.isHidden = true
        cardContainer.addSubview(interactiveWebContainer)

        appIconTile.translatesAutoresizingMaskIntoConstraints = false
        bodyContentContainer.addSubview(appIconTile)

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        promptLabel.textColor = .labelColor
        promptLabel.alignment = .center
        promptLabel.maximumNumberOfLines = 2
        bodyContentContainer.addSubview(promptLabel)

        accountsStack.translatesAutoresizingMaskIntoConstraints = false
        accountsStack.orientation = .vertical
        accountsStack.alignment = .width
        accountsStack.spacing = 8
        bodyContentContainer.addSubview(accountsStack)

        emailScopeStack.translatesAutoresizingMaskIntoConstraints = false
        emailScopeStack.orientation = .horizontal
        emailScopeStack.alignment = .centerY
        emailScopeStack.spacing = 12
        emailScopeStack.isHidden = true
        bodyContentContainer.addSubview(emailScopeStack)

        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        bodyContentContainer.addSubview(separatorLine)

        secondaryLinkButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryLinkButton.onClick = { [weak self] in
            self?.onSecondaryAction?()
        }
        bodyContentContainer.addSubview(secondaryLinkButton)

        scannerView.translatesAutoresizingMaskIntoConstraints = false
        scannerView.onActivateScanner = { [weak self] in
            self?.onActivateBiometricScanner?()
        }
        bodyContentContainer.addSubview(scannerView)

        let webHeight = interactiveWebContainer.heightAnchor.constraint(equalToConstant: 0)
        self.interactiveWebHeightConstraint = webHeight
        let sepToAccounts = separatorLine.topAnchor.constraint(equalTo: accountsStack.bottomAnchor, constant: 18)
        let sepToEmail = separatorLine.topAnchor.constraint(equalTo: emailScopeStack.bottomAnchor, constant: 14)
        self.separatorTopToAccountsConstraint = sepToAccounts
        self.separatorTopToEmailConstraint = sepToEmail

        NSLayoutConstraint.activate([
            backdropSnapshotView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropSnapshotView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropSnapshotView.topAnchor.constraint(equalTo: topAnchor),
            backdropSnapshotView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrimView.topAnchor.constraint(equalTo: topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardContainer.widthAnchor.constraint(equalToConstant: 440),
            cardContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            cardContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            headerTitleLabel.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 21),
            headerTitleLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 22),
            headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelPillButton.leadingAnchor, constant: -12),

            cancelPillButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            cancelPillButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -20),

            bodyContentContainer.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 22),
            bodyContentContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            bodyContentContainer.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            bodyContentContainer.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -22),

            appIconTile.topAnchor.constraint(equalTo: bodyContentContainer.topAnchor),
            appIconTile.centerXAnchor.constraint(equalTo: bodyContentContainer.centerXAnchor),
            appIconTile.widthAnchor.constraint(equalToConstant: 48),
            appIconTile.heightAnchor.constraint(equalToConstant: 48),

            promptLabel.topAnchor.constraint(equalTo: appIconTile.bottomAnchor, constant: 16),
            promptLabel.leadingAnchor.constraint(equalTo: bodyContentContainer.leadingAnchor, constant: 34),
            promptLabel.trailingAnchor.constraint(equalTo: bodyContentContainer.trailingAnchor, constant: -34),

            accountsStack.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 14),
            accountsStack.leadingAnchor.constraint(equalTo: bodyContentContainer.leadingAnchor, constant: 34),
            accountsStack.trailingAnchor.constraint(equalTo: bodyContentContainer.trailingAnchor, constant: -34),

            emailScopeStack.topAnchor.constraint(equalTo: accountsStack.bottomAnchor, constant: 10),
            emailScopeStack.centerXAnchor.constraint(equalTo: bodyContentContainer.centerXAnchor),

            sepToAccounts,
            separatorLine.leadingAnchor.constraint(equalTo: bodyContentContainer.leadingAnchor, constant: 16),
            separatorLine.trailingAnchor.constraint(equalTo: bodyContentContainer.trailingAnchor, constant: -16),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0),

            secondaryLinkButton.topAnchor.constraint(equalTo: separatorLine.bottomAnchor, constant: 20),
            secondaryLinkButton.centerXAnchor.constraint(equalTo: bodyContentContainer.centerXAnchor),

            scannerView.topAnchor.constraint(equalTo: secondaryLinkButton.bottomAnchor, constant: 18),
            scannerView.leadingAnchor.constraint(equalTo: bodyContentContainer.leadingAnchor, constant: 24),
            scannerView.trailingAnchor.constraint(equalTo: bodyContentContainer.trailingAnchor, constant: -24),
            scannerView.bottomAnchor.constraint(equalTo: bodyContentContainer.bottomAnchor),

            interactiveWebContainer.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 14),
            interactiveWebContainer.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 16),
            interactiveWebContainer.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -16),
            webHeight
        ])

        updateAdaptiveColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAdaptiveColors()
    }

    private func isDarkMode() -> Bool {
        let sourceAppearance: NSAppearance
        if let explicit = self.appearance {
            sourceAppearance = explicit
        } else if let appAppearance = NSApp?.effectiveAppearance {
            sourceAppearance = appAppearance
        } else {
            sourceAppearance = effectiveAppearance
        }
        return sourceAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func updateAdaptiveColors() {
        let dark = isDarkMode()
        cardContainer.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        cardContainer.layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.168, alpha: 1.0)
            : NSColor.white).cgColor
        cardContainer.layer?.borderWidth = 0.5
        cardContainer.layer?.borderColor = (dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.14)
            : NSColor(calibratedWhite: 0.0, alpha: 0.08)).cgColor
        separatorLine.layer?.backgroundColor = (dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.12)
            : NSColor(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1.0)).cgColor
        cancelPillButton.updateColors(isDark: dark)
        for case let card as SafariAccountCardRowView in accountsStack.arrangedSubviews {
            card.updateColors(isDark: dark)
        }
    }

    func updateSiteIcon(_ image: NSImage?, fallbackTitle: String) {
        appIconTile.configure(image: image, fallbackTitle: fallbackTitle)
    }

    func setFrozenBackdropSnapshot(_ image: NSImage?) {
        backdropSnapshotView.image = image
        backdropSnapshotView.isHidden = (image == nil) || isShowingInteractiveWebAuth
    }

    func applyConfiguration(_ newKind: SafariBiometricSheetKind) {
        self.kind = newKind
        accountsStack.arrangedSubviews.forEach {
            accountsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emailScopeStack.arrangedSubviews.forEach {
            emailScopeStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch newKind {
        case .signInWithApple(let cfg):
            headerTitleLabel.stringValue = "Sign in with Apple"
            appIconTile.configure(image: cfg.siteIcon, fallbackTitle: cfg.siteDisplayName)
            promptLabel.stringValue = "Sign in to \(cfg.siteDisplayName) using your Apple Account."
            let acct = SafariBiometricAccountOption(
                id: "primary_apple_account",
                title: cfg.accountName,
                subtitle: cfg.accountSubtitle,
                initials: SafariBiometricAccountOption.computeInitials(from: cfg.accountName)
            )
            let row = SafariAccountCardRowView(option: acct, selectable: false, isSelected: false)
            row.updateColors(isDark: isDarkMode())
            accountsStack.addArrangedSubview(row)

            hideMyEmail = cfg.hideMyEmailSelected
            if cfg.requestsEmailScope {
                emailScopeStack.isHidden = false
                separatorTopToAccountsConstraint?.isActive = false
                separatorTopToEmailConstraint?.isActive = true
                let shareBtn = NSButton(radioButtonWithTitle: "Share My Email", target: self, action: #selector(emailRadioChanged(_:)))
                shareBtn.tag = 0
                shareBtn.font = NSFont.systemFont(ofSize: 12)
                shareBtn.state = hideMyEmail ? .off : .on
                let hideBtn = NSButton(radioButtonWithTitle: "Hide My Email", target: self, action: #selector(emailRadioChanged(_:)))
                hideBtn.tag = 1
                hideBtn.font = NSFont.systemFont(ofSize: 12)
                hideBtn.state = hideMyEmail ? .on : .off
                emailScopeStack.addArrangedSubview(shareBtn)
                emailScopeStack.addArrangedSubview(hideBtn)
            } else {
                emailScopeStack.isHidden = true
                separatorTopToEmailConstraint?.isActive = false
                separatorTopToAccountsConstraint?.isActive = true
            }

            separatorLine.isHidden = false
            secondaryLinkButton.isHidden = false
            secondaryLinkButton.titleText = "Use a different Apple Account"
            scannerView.defaultPromptText = "Continue with Touch ID"

        case .passkeySignIn(let cfg):
            headerTitleLabel.stringValue = "Sign in"
            appIconTile.configure(image: cfg.siteIcon, fallbackTitle: cfg.rpDisplayName)
            promptLabel.stringValue = cfg.accounts.count > 1
                ? "Choose a passkey to sign in to \(cfg.rpDisplayName)."
                : "Sign in to \(cfg.rpDisplayName) with a passkey."
            selectedAccountIndex = max(0, min(cfg.selectedAccountIndex, max(0, cfg.accounts.count - 1)))
            let multi = cfg.accounts.count > 1
            for (idx, opt) in cfg.accounts.prefix(4).enumerated() {
                let row = SafariAccountCardRowView(option: opt, selectable: multi, isSelected: idx == selectedAccountIndex)
                row.updateColors(isDark: isDarkMode())
                row.onSelect = { [weak self] in
                    self?.selectAccount(at: idx)
                }
                accountsStack.addArrangedSubview(row)
            }
            emailScopeStack.isHidden = true
            separatorTopToEmailConstraint?.isActive = false
            separatorTopToAccountsConstraint?.isActive = true
            separatorLine.isHidden = false
            secondaryLinkButton.isHidden = false
            secondaryLinkButton.titleText = "Sign in with iPhone, iPad, or Android Device…"
            scannerView.defaultPromptText = "Continue with Touch ID"

        case .passkeyCreate(let cfg):
            headerTitleLabel.stringValue = "Save a Passkey"
            appIconTile.configure(image: cfg.siteIcon, fallbackTitle: cfg.rpDisplayName)
            promptLabel.stringValue = "Save a passkey for “\(cfg.account.title)” on \(cfg.rpDisplayName)."
            let row = SafariAccountCardRowView(option: cfg.account, selectable: false, isSelected: false)
            row.updateColors(isDark: isDarkMode())
            accountsStack.addArrangedSubview(row)
            emailScopeStack.isHidden = true
            separatorTopToEmailConstraint?.isActive = false
            separatorTopToAccountsConstraint?.isActive = true
            separatorLine.isHidden = false
            secondaryLinkButton.isHidden = false
            secondaryLinkButton.titleText = "Save on Another Device…"
            scannerView.defaultPromptText = "Continue with Touch ID"

        case .passwordAutoFill(let cfg):
            headerTitleLabel.stringValue = "AutoFill Password"
            appIconTile.configure(image: cfg.siteIcon, fallbackTitle: cfg.siteDisplayName)
            promptLabel.stringValue = "Fill your saved password for \(cfg.siteDisplayName)."
            let row = SafariAccountCardRowView(option: cfg.account, selectable: false, isSelected: false)
            row.updateColors(isDark: isDarkMode())
            accountsStack.addArrangedSubview(row)
            emailScopeStack.isHidden = true
            separatorTopToEmailConstraint?.isActive = false
            separatorTopToAccountsConstraint?.isActive = true
            separatorLine.isHidden = false
            secondaryLinkButton.isHidden = true
            scannerView.defaultPromptText = "Continue with Touch ID"
        }
    }

    private func selectAccount(at index: Int) {
        selectedAccountIndex = index
        let dark = isDarkMode()
        for (i, view) in accountsStack.arrangedSubviews.enumerated() {
            if let row = view as? SafariAccountCardRowView {
                row.setSelected(i == index, isDark: dark)
            }
        }
        onSelectAccountIndex?(index)
    }

    @objc private func emailRadioChanged(_ sender: NSButton) {
        hideMyEmail = (sender.tag == 1)
        for case let btn as NSButton in emailScopeStack.arrangedSubviews {
            btn.state = (btn.tag == sender.tag) ? .on : .off
        }
        onEmailPrivacyChanged?(hideMyEmail)
    }

    /// Smoothly reveals the live `appleid.apple.com` / `idmsa.apple.com` child web view inside the Safari sheet
    /// when initial Apple Account bootstrap, 2FA code entry, or "Use a different Apple Account" is needed.
    func revealInteractiveWebAuthView(_ webView: NSView) {
        guard !isShowingInteractiveWebAuth else { return }
        isShowingInteractiveWebAuth = true

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        interactiveWebContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: interactiveWebContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: interactiveWebContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: interactiveWebContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: interactiveWebContainer.bottomAnchor)
        ])

        bodyContentContainer.isHidden = true
        interactiveWebContainer.isHidden = false
        interactiveWebHeightConstraint?.constant = 460
        let bottomPin = interactiveWebContainer.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -16)
        bottomPin.priority = .defaultHigh
        bottomPin.isActive = true

        layoutSubtreeIfNeeded()
    }

    // Intercept background clicks so underlying webpage controls cannot be clicked through the scrim
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        if !isShowingInteractiveWebAuth && (event.keyCode == 36 || event.keyCode == 49) {
            onActivateBiometricScanner?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Testing & Inspection Accessors

    var displayedHeaderTitle: String { headerTitleLabel.stringValue }
    var displayedPromptText: String { promptLabel.stringValue }
    var displayedSecondaryActionTitle: String { secondaryLinkButton.titleText }
    var currentSelectedAccountIndex: Int { selectedAccountIndex }
}

// MARK: - Supporting Safari Sheet Subcomponents

private final class SafariSheetCancelPillButton: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "Cancel")
    private var isPressed = false
    private var isDark = false

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12.5
        layer?.cornerCurve = .continuous

        label.stringValue = title
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 25),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColors(isDark: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateColors(isDark: Bool) {
        self.isDark = isDark
        label.textColor = isDark
            ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
            : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1.0)
        refreshBackground()
    }

    private func refreshBackground() {
        if isDark {
            layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: isPressed ? 0.22 : 0.14).cgColor
        } else {
            layer?.backgroundColor = (isPressed
                ? NSColor(srgbRed: 0.855, green: 0.855, blue: 0.882, alpha: 1.0)
                : NSColor(srgbRed: 0.910, green: 0.910, blue: 0.929, alpha: 1.0)).cgColor // #E8E8ED
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        refreshBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        refreshBackground()
        let pt = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.insetBy(dx: -4, dy: -4).contains(pt) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

private final class SafariSquircleAppIconView: NSView {
    private let imageView = NSImageView()
    private let monogramLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11.0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.12).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        monogramLabel.translatesAutoresizingMaskIntoConstraints = false
        monogramLabel.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        monogramLabel.textColor = .white
        monogramLabel.alignment = .center
        addSubview(monogramLabel)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),
            monogramLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            monogramLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: NSImage?, fallbackTitle: String) {
        if let image, image.size.width > 1, image.size.height > 1 {
            imageView.image = image
            imageView.isHidden = false
            monogramLabel.isHidden = true
            // Dark graphite squircle tile (matching Safari's app icon tile in `5B6A87E4-A2BB...`)
            // so both transparent SVG favicons and full-bleed icons look crisp!
            layer?.backgroundColor = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.165, alpha: 1.0).cgColor
        } else {
            imageView.image = nil
            imageView.isHidden = true
            monogramLabel.isHidden = false
            let ch = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "S"
            monogramLabel.stringValue = ch
            layer?.backgroundColor = NSColor(srgbRed: 0.22, green: 0.24, blue: 0.29, alpha: 1.0).cgColor
        }
    }
}

private final class SafariAccountCardRowView: NSView {
    var onSelect: (() -> Void)?

    private let avatarCircle = NSView()
    private let initialsLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let checkImageView = NSImageView()
    private let selectable: Bool
    private var isSelected: Bool

    init(option: SafariBiometricAccountOption, selectable: Bool, isSelected: Bool) {
        self.selectable = selectable
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8.5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75

        avatarCircle.translatesAutoresizingMaskIntoConstraints = false
        avatarCircle.wantsLayer = true
        avatarCircle.layer?.cornerRadius = 18.0
        // Exact Safari soft slate-periwinkle monogram circle (`#8EA7CE`)
        avatarCircle.layer?.backgroundColor = NSColor(srgbRed: 0.557, green: 0.655, blue: 0.808, alpha: 1.0).cgColor
        addSubview(avatarCircle)

        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.stringValue = option.initials
        initialsLabel.font = NSFont.systemFont(ofSize: 14.0, weight: .medium)
        initialsLabel.textColor = .white
        initialsLabel.alignment = .center
        avatarCircle.addSubview(initialsLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = option.title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.stringValue = option.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1.0
        addSubview(textStack)

        checkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkImageView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        checkImageView.contentTintColor = .controlAccentColor
        checkImageView.isHidden = !(selectable && isSelected)
        addSubview(checkImageView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),

            avatarCircle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatarCircle.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarCircle.widthAnchor.constraint(equalToConstant: 36),
            avatarCircle.heightAnchor.constraint(equalToConstant: 36),

            initialsLabel.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkImageView.leadingAnchor, constant: -10),

            checkImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkImageView.widthAnchor.constraint(equalToConstant: 18),
            checkImageView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool, isDark: Bool) {
        self.isSelected = selected
        checkImageView.isHidden = !(selectable && selected)
        updateColors(isDark: isDark)
    }

    func updateColors(isDark: Bool) {
        if selectable && isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.18 : 0.08).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else if isDark {
            layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor(srgbRed: 0.976, green: 0.976, blue: 0.984, alpha: 1.0).cgColor // #F9F9FB
            layer?.borderColor = NSColor(srgbRed: 0.886, green: 0.886, blue: 0.906, alpha: 1.0).cgColor     // #E2E2E7
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard selectable else { return }
        alphaValue = 0.82
    }

    override func mouseUp(with event: NSEvent) {
        guard selectable else { return }
        alphaValue = 1.0
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onSelect?()
        }
    }
}

private final class SafariBlueLinkButton: NSView {
    var onClick: (() -> Void)?
    var titleText: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .linkColor
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.62
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1.0
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -6, dy: -4).contains(pt) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
