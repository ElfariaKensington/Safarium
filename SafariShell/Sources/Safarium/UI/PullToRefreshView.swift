import AppKit
import QuartzCore

/// Pure GPU-driven Safari 27.3 Pull-to-Refresh Spinner view.
///
/// Built directly from the 40 extracted Safari spinner frames (`pull-01@2x.png` .. `pull-24@2x.png`
/// and `spin-00@2x.png` .. `spin-15@2x.png`) and exact frame measurements from real Safari recordings:
/// - `22 × 22 pt` natural spinner diameter
/// - Fixed vertically centered `32 pt` below the `52 pt` unified toolbar (`top = 21 pt`, `bottom = 43 pt`
///   inside `contentStageView`), centered horizontally in the active content pane
/// - Sits behind `webContentHost` over `extensionBackdropFill` so sliding webpage content naturally
///   reveals and covers the spinner with zero clipping glitches
final class PullToRefreshView: NSView {

    enum DisplayState: Equatable {
        case hidden
        case pulling(progress: CGFloat, opacity: CGFloat)
        case spinning(popScale: CGFloat, opacity: CGFloat, shiftUp: CGFloat = 0.0)
    }

    static let spinnerSize: CGFloat = 22.0
    /// Measured in real Safari (`f_100111`): window centerY = 83.9 pt = 52 pt toolbar + 32 pt.
    static let centerOffsetBelowToolbar: CGFloat = 32.0

    private let spinnerHostLayer = CALayer()
    private let spinnerMaskLayer = CALayer()

    private(set) var pullImages: [CGImage] = []
    private(set) var spinImages: [CGImage] = []
    private var prefersLightInk: Bool = false

    private var lastState: DisplayState = .hidden
    private var lastSpinFrameIndex: Int = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        loadSpinnerFrames()
        configureSpinnerLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pure visual overlay beneath web content — never intercept pointer events.
        return nil
    }

    override func layout() {
        super.layout()
        positionSpinnerLayer()
    }

    /// Updates spinner spoke tint to stay crisp over both light and dark top-edge page surfaces.
    func apply(theme: AdaptiveChromeTheme) {
        prefersLightInk = theme.prefersLightInk
        let tint: NSColor = prefersLightInk
            ? NSColor(white: 0.94, alpha: 0.85)
            : NSColor(white: 0.36, alpha: 0.88)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerHostLayer.backgroundColor = tint.cgColor
        CATransaction.commit()
    }

    /// Renders the exact spinner frame, opacity, and pop scale at 120Hz with zero implicit CA animations.
    func render(state: DisplayState, spinFrameIndex: Int = 0) {
        if state == lastState && spinFrameIndex == lastSpinFrameIndex {
            return
        }
        lastState = state
        lastSpinFrameIndex = spinFrameIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch state {
        case .hidden:
            spinnerHostLayer.opacity = 0.0
            spinnerHostLayer.isHidden = true
            spinnerHostLayer.transform = CATransform3DIdentity

        case .pulling(let progress, let opacity):
            let clampedProgress = max(0.0, min(1.0, progress))
            let clampedOpacity = Float(max(0.0, min(1.0, opacity)))
            if !pullImages.isEmpty {
                let idx = min(pullImages.count - 1, max(0, Int((clampedProgress * CGFloat(pullImages.count - 1)).rounded())))
                spinnerMaskLayer.contents = pullImages[idx]
            }
            spinnerHostLayer.isHidden = clampedOpacity <= 0.005
            spinnerHostLayer.opacity = clampedOpacity
            spinnerHostLayer.transform = CATransform3DIdentity

        case .spinning(let popScale, let opacity, let shiftUp):
            let clampedOpacity = Float(max(0.0, min(1.0, opacity)))
            if !spinImages.isEmpty {
                let idx = ((spinFrameIndex % spinImages.count) + spinImages.count) % spinImages.count
                spinnerMaskLayer.contents = spinImages[idx]
            }
            spinnerHostLayer.isHidden = clampedOpacity <= 0.005
            spinnerHostLayer.opacity = clampedOpacity
            let s = max(0.01, popScale)
            let shiftSign: CGFloat = isFlipped ? -1.0 : 1.0
            var transform = CATransform3DMakeTranslation(0.0, shiftSign * max(0.0, shiftUp), 0.0)
            transform = CATransform3DScale(transform, s, s, 1.0)
            spinnerHostLayer.transform = transform
        }
    }

    // MARK: - Private Setup

    private func configureSpinnerLayers() {
        let size = Self.spinnerSize
        spinnerHostLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        spinnerHostLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinnerHostLayer.backgroundColor = NSColor(white: 0.36, alpha: 0.88).cgColor
        spinnerHostLayer.opacity = 0.0
        spinnerHostLayer.isHidden = true
        spinnerHostLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        spinnerMaskLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        spinnerMaskLayer.contentsGravity = .resizeAspect
        spinnerMaskLayer.contentsScale = 2.0
        spinnerHostLayer.mask = spinnerMaskLayer

        layer?.addSublayer(spinnerHostLayer)
        positionSpinnerLayer()
    }

    private func positionSpinnerLayer() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cx = (bounds.width * 0.5).rounded()
        // In AppKit non-flipped coordinates, y = bounds.height is the top edge (right below 52pt toolbar).
        let cy: CGFloat = isFlipped
            ? Self.centerOffsetBelowToolbar
            : (bounds.height - Self.centerOffsetBelowToolbar)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerHostLayer.position = CGPoint(x: cx, y: cy.rounded())
        CATransaction.commit()
    }

    /// Decoded once per process: every new window used to re-read and decode up to 40 PNGs on the main thread.
    nonisolated(unsafe) private static var sharedFrames: (dir: String, pulls: [CGImage], spins: [CGImage])?

    private func loadSpinnerFrames() {
        let spinnerDir = AssetLoader.shared.referenceRootURL
            .appendingPathComponent("Animations/spinner", isDirectory: true)
            .resolvingSymlinksInPath()
        if let cached = Self.sharedFrames, cached.dir == spinnerDir.path {
            pullImages = cached.pulls
            spinImages = cached.spins
            return
        }

        var pulls: [CGImage] = []
        pulls.reserveCapacity(24)
        for i in 1...24 {
            let name = String(format: "pull-%02d@2x.png", i)
            if let cg = loadCGImage(at: spinnerDir.appendingPathComponent(name)) {
                pulls.append(cg)
            }
        }
        pullImages = pulls

        var spins: [CGImage] = []
        spins.reserveCapacity(16)
        for i in 0...15 {
            let name = String(format: "spin-%02d@2x.png", i)
            if let cg = loadCGImage(at: spinnerDir.appendingPathComponent(name)) {
                spins.append(cg)
            }
        }
        spinImages = spins
        if !pulls.isEmpty || !spins.isEmpty { Self.sharedFrames = (spinnerDir.path, pulls, spins) }
    }

    private func loadCGImage(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
    }
}
