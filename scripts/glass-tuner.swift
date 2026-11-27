import AppKit
import QuartzCore

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class GlassTunerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var previewScrollView: NSScrollView!
    private var previewDocView: FlippedView!
    private var glassHostView: NSView!
    private var backdropLayer: CALayer!
    private let tintLayer = CAGradientLayer()
    private var nativeGlassView: NSView?
    private var toolbarButtonsHost: NSView!

    // Parameters
    private var displacementAmount: Double = 56.0
    private var chromaticAmount: Double = 2.5
    private var blurRadius: Double = 0.0
    private var saturation: Double = 1.15
    private var tintOpacity: Double = 0.08
    private var edgeHeight: Double = 18.0
    private var rippleStrength: Double = 0.42
    private var rippleFrequency: Double = 6.0
    private var verticalCurve: Double = 0.78
    private var modeIndex: Int = 0 // 0: Disp->Chrom->Blur, 1: Blur->Disp->Chrom, 2: NSGlass(.clear), 3: NSGlass(.regular)
    private var polarityIndex: Int = 0 // 0: Bipolar shared 128, 1: Positive disp 128..255 + Chrom 0..255, 2: Bipolar disp + Chrom 0..255
    private var themeIndex: Int = 0 // 0: Light Editorial, 1: Dark Fixed Bar (apple.com), 2: Neon Grid

    private var valueLabels: [String: NSTextField] = [:]
    private var sliders: [String: NSSlider] = [:]
    private var popups: [String: NSPopUpButton] = [:]
    private var glassBarHeight: Double = 120.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Safarium Glass & Refraction Tuner"
        window.minSize = NSSize(width: 960, height: 640)
        window.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 740))
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        window.contentMinSize = NSSize(width: 960, height: 640)

        let sidebarW: CGFloat = 340
        let previewW: CGFloat = 1120 - sidebarW - 1

        // Left: Live scrollable browser preview
        let previewContainer = NSView(frame: NSRect(x: 0, y: 0, width: previewW, height: 740))
        previewContainer.autoresizingMask = [.width, .height]
        previewContainer.wantsLayer = true
        root.addSubview(previewContainer)

        previewScrollView = NSScrollView(frame: previewContainer.bounds)
        previewScrollView.autoresizingMask = [.width, .height]
        previewScrollView.hasVerticalScroller = true
        previewScrollView.drawsBackground = false
        previewContainer.addSubview(previewScrollView)

        previewDocView = FlippedView(frame: NSRect(x: 0, y: 0, width: previewW, height: 1800))
        previewDocView.wantsLayer = true
        previewScrollView.documentView = previewDocView

        // Glass toolbar overlay (top of previewContainer in non-flipped coordinates)
        let initGlassH = CGFloat(glassBarHeight + edgeHeight)
        glassHostView = NSView(frame: NSRect(x: 0, y: 740 - initGlassH, width: previewW, height: initGlassH))
        glassHostView.autoresizingMask = [.width, .minYMargin]
        glassHostView.wantsLayer = true
        glassHostView.layer?.masksToBounds = false
        previewContainer.addSubview(glassHostView)

        // Sample toolbar buttons on top of glass
        toolbarButtonsHost = NSView(frame: NSRect(x: 0, y: 740 - CGFloat(glassBarHeight), width: previewW, height: CGFloat(glassBarHeight)))
        toolbarButtonsHost.autoresizingMask = [.width, .minYMargin]
        previewContainer.addSubview(toolbarButtonsHost)
        buildMockToolbarButtons()

        // Vertical divider
        let divider = NSBox(frame: NSRect(x: previewW, y: 0, width: 1, height: 740))
        divider.autoresizingMask = [.minXMargin, .height]
        divider.boxType = .separator
        root.addSubview(divider)

        // Right: Control sidebar (340pt)
        let controlsScroll = NSScrollView(frame: NSRect(x: previewW + 1, y: 0, width: sidebarW, height: 740))
        controlsScroll.autoresizingMask = [.minXMargin, .height]
        controlsScroll.hasVerticalScroller = true
        controlsScroll.drawsBackground = true
        controlsScroll.backgroundColor = .windowBackgroundColor
        root.addSubview(controlsScroll)

        let controlsDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: 860))
        controlsScroll.documentView = controlsDoc
        buildControls(in: controlsDoc)

        setupGlassLayers()
        rebuildPreviewPage()
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.center()
        layoutGlassLayers()
        applyGlassParameters()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        layoutGlassLayers()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func buildMockToolbarButtons() {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 15
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.32).cgColor
        pill.layer?.borderWidth = 0.75
        pill.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        toolbarButtonsHost.addSubview(pill)

        let urlLbl = NSTextField(labelWithString: "safarium.app — scroll below to test glass")
        urlLbl.translatesAutoresizingMaskIntoConstraints = false
        urlLbl.font = .systemFont(ofSize: 12.5, weight: .medium)
        urlLbl.alignment = .center
        pill.addSubview(urlLbl)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: toolbarButtonsHost.centerXAnchor, constant: 20),
            pill.centerYAnchor.constraint(equalTo: toolbarButtonsHost.centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: 320),
            pill.heightAnchor.constraint(equalToConstant: 30),

            urlLbl.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            urlLbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
    }

    private func setupGlassLayers() {
        guard let root = glassHostView.layer else { return }
        tintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 0)

        let backdropCls = NSClassFromString("CABackdropLayer") as! CALayer.Type
        backdropLayer = backdropCls.init()
        if backdropLayer.responds(to: NSSelectorFromString("setWindowServerAware:")) {
            backdropLayer.setValue(true, forKey: "windowServerAware")
        }
        backdropLayer.setValue(1.0, forKey: "scale")
        root.addSublayer(backdropLayer)
        root.addSublayer(tintLayer)

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .clear
            gv.cornerRadius = 16
            gv.wantsLayer = true
            gv.isHidden = true
            glassHostView.addSubview(gv)
            nativeGlassView = gv
        }
        layoutGlassLayers()
    }

    private func layoutGlassLayers() {
        let barH = CGFloat(glassBarHeight)
        let totalH = barH + CGFloat(edgeHeight)
        if let parent = glassHostView.superview {
            glassHostView.frame = NSRect(x: 0, y: parent.bounds.height - totalH, width: parent.bounds.width, height: totalH)
            toolbarButtonsHost.frame = NSRect(x: 0, y: parent.bounds.height - barH, width: parent.bounds.width, height: barH)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer?.frame = glassHostView.bounds
        tintLayer.frame = glassHostView.bounds
        nativeGlassView?.frame = NSRect(x: 0, y: CGFloat(edgeHeight), width: glassHostView.bounds.width, height: barH)
        CATransaction.commit()
    }

    // MARK: - Controls (Explicit Frame Layout — zero Auto Layout hit-test issues)

    private func buildControls(in container: FlippedView) {
        var y: CGFloat = 16
        let x: CGFloat = 16
        let w: CGFloat = 300

        func addPopup(id: String, title: String, items: [String], selected: Int, action: Selector) {
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: x, y: y, width: w, height: 16)
            lbl.font = .systemFont(ofSize: 11.5, weight: .semibold)
            lbl.textColor = .secondaryLabelColor
            container.addSubview(lbl)
            y += 18

            let pop = NSPopUpButton(frame: NSRect(x: x, y: y, width: w, height: 26), pullsDown: false)
            pop.addItems(withTitles: items)
            pop.selectItem(at: selected)
            pop.target = self
            pop.action = action
            container.addSubview(pop)
            popups[id] = pop
            y += 34
        }

        func addSlider(id: String, title: String, min: Double, max: Double, val: Double, action: Selector) {
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: x, y: y, width: w - 64, height: 16)
            lbl.font = .systemFont(ofSize: 11.5, weight: .medium)
            container.addSubview(lbl)

            let valLbl = NSTextField(labelWithString: String(format: "%.2f", val))
            valLbl.frame = NSRect(x: x + w - 64, y: y, width: 64, height: 16)
            valLbl.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            valLbl.alignment = .right
            container.addSubview(valLbl)
            valueLabels[id] = valLbl
            y += 18

            let slider = NSSlider(frame: NSRect(x: x, y: y, width: w, height: 22))
            slider.minValue = min
            slider.maxValue = max
            slider.doubleValue = val
            slider.target = self
            slider.action = action
            slider.isContinuous = true
            container.addSubview(slider)
            sliders[id] = slider
            y += 28
        }

        addPopup(id: "mode", title: "Pipeline Mode:", items: [
            "Disp -> Chrom -> Blur",
            "Blur -> Disp -> Chrom",
            "Native NSGlassEffectView (.clear)",
            "Native NSGlassEffectView (.regular)"
        ], selected: modeIndex, action: #selector(modeChanged(_:)))

        addPopup(id: "polarity", title: "Map Polarity:", items: [
            "Bipolar Shared (128±wave)",
            "Positive Disp (128..255) + Chrom (0..255)",
            "Bipolar Disp (128±) + Chrom (0..255)"
        ], selected: polarityIndex, action: #selector(polarityChanged(_:)))

        addPopup(id: "theme", title: "Preview Page:", items: [
            "Light Editorial + Colors",
            "Dark + Fixed Header (apple.com)",
            "High-Contrast Color Grid"
        ], selected: themeIndex, action: #selector(themeChanged(_:)))

        y += 4
        addSlider(id: "barh", title: "Glass Bar Height (pt)", min: 48, max: 240, val: glassBarHeight, action: #selector(barHChanged(_:)))
        addSlider(id: "disp", title: "Distortion (displacementMap)", min: 0, max: 120, val: displacementAmount, action: #selector(dispChanged(_:)))
        addSlider(id: "chrom", title: "Chromatic Refraction", min: 0, max: 25, val: chromaticAmount, action: #selector(chromChanged(_:)))
        addSlider(id: "blur", title: "Blur / Frost Radius", min: 0, max: 30, val: blurRadius, action: #selector(blurChanged(_:)))
        addSlider(id: "sat", title: "Color Saturation", min: 0.5, max: 2.5, val: saturation, action: #selector(satChanged(_:)))
        addSlider(id: "tint", title: "Tint Opacity", min: 0, max: 0.9, val: tintOpacity, action: #selector(tintChanged(_:)))
        addSlider(id: "edge", title: "Edge Fade Height (pt)", min: 0, max: 40, val: edgeHeight, action: #selector(edgeChanged(_:)))
        addSlider(id: "rx", title: "Horizontal Ripple Strength", min: 0, max: 1.0, val: rippleStrength, action: #selector(rxChanged(_:)))
        addSlider(id: "rf", title: "Horizontal Ripple Freq", min: 1, max: 12, val: rippleFrequency, action: #selector(rfChanged(_:)))
        addSlider(id: "vy", title: "Vertical Lens Curve", min: 0, max: 1.5, val: verticalCurve, action: #selector(vyChanged(_:)))

        y += 8
        let copyBtn = NSButton(frame: NSRect(x: x, y: y, width: 150, height: 28))
        copyBtn.title = "Copy Parameters"
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyParametersClicked)
        container.addSubview(copyBtn)

        let resetBtn = NSButton(frame: NSRect(x: x + 162, y: y, width: 90, height: 28))
        resetBtn.title = "Reset"
        resetBtn.bezelStyle = .rounded
        resetBtn.target = self
        resetBtn.action = #selector(resetClicked)
        container.addSubview(resetBtn)

        y += 44
        container.frame.size.height = max(740, y)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) { modeIndex = sender.indexOfSelectedItem; applyGlassParameters() }
    @objc private func polarityChanged(_ sender: NSPopUpButton) { polarityIndex = sender.indexOfSelectedItem; applyGlassParameters() }
    @objc private func themeChanged(_ sender: NSPopUpButton) { themeIndex = sender.indexOfSelectedItem; rebuildPreviewPage(); applyGlassParameters() }
    @objc private func barHChanged(_ sender: NSSlider) { glassBarHeight = sender.doubleValue; valueLabels["barh"]?.stringValue = String(format: "%.0f", glassBarHeight); layoutGlassLayers(); applyGlassParameters() }
    @objc private func dispChanged(_ sender: NSSlider) { displacementAmount = sender.doubleValue; valueLabels["disp"]?.stringValue = String(format: "%.1f", displacementAmount); applyGlassParameters() }
    @objc private func chromChanged(_ sender: NSSlider) { chromaticAmount = sender.doubleValue; valueLabels["chrom"]?.stringValue = String(format: "%.2f", chromaticAmount); applyGlassParameters() }
    @objc private func blurChanged(_ sender: NSSlider) { blurRadius = sender.doubleValue; valueLabels["blur"]?.stringValue = String(format: "%.1f", blurRadius); applyGlassParameters() }
    @objc private func satChanged(_ sender: NSSlider) { saturation = sender.doubleValue; valueLabels["sat"]?.stringValue = String(format: "%.2f", saturation); applyGlassParameters() }
    @objc private func tintChanged(_ sender: NSSlider) { tintOpacity = sender.doubleValue; valueLabels["tint"]?.stringValue = String(format: "%.2f", tintOpacity); applyGlassParameters() }
    @objc private func edgeChanged(_ sender: NSSlider) { edgeHeight = sender.doubleValue; valueLabels["edge"]?.stringValue = String(format: "%.0f", edgeHeight); layoutGlassLayers(); applyGlassParameters() }
    @objc private func rxChanged(_ sender: NSSlider) { rippleStrength = sender.doubleValue; valueLabels["rx"]?.stringValue = String(format: "%.2f", rippleStrength); applyGlassParameters() }
    @objc private func rfChanged(_ sender: NSSlider) { rippleFrequency = sender.doubleValue; valueLabels["rf"]?.stringValue = String(format: "%.1f", rippleFrequency); applyGlassParameters() }
    @objc private func vyChanged(_ sender: NSSlider) { verticalCurve = sender.doubleValue; valueLabels["vy"]?.stringValue = String(format: "%.2f", verticalCurve); applyGlassParameters() }

    @objc private func copyParametersClicked() {
        let modes = ["Disp->Chrom->Blur", "Blur->Disp->Chrom", "NSGlass(.clear)", "NSGlass(.regular)"]
        let pols = ["Bipolar128", "PosDisp+Chrom0", "BipolarDisp+Chrom0"]
        let summary = """
        mode=\(modes[modeIndex]), polarity=\(pols[polarityIndex]), disp=\(String(format: "%.1f", displacementAmount)), chrom=\(String(format: "%.2f", chromaticAmount)), blur=\(String(format: "%.1f", blurRadius)), sat=\(String(format: "%.2f", saturation)), tint=\(String(format: "%.2f", tintOpacity)), edge=\(String(format: "%.0f", edgeHeight)), rippleX=\(String(format: "%.2f", rippleStrength)), rippleFreq=\(String(format: "%.1f", rippleFrequency)), vertCurve=\(String(format: "%.2f", verticalCurve))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    @objc private func resetClicked() {
        glassBarHeight = 120; displacementAmount = 56; chromaticAmount = 2.5; blurRadius = 0; saturation = 1.15
        tintOpacity = 0.08; edgeHeight = 18; rippleStrength = 0.42; rippleFrequency = 6; verticalCurve = 0.78
        sliders["barh"]?.doubleValue = glassBarHeight; valueLabels["barh"]?.stringValue = "120"
        sliders["disp"]?.doubleValue = displacementAmount; valueLabels["disp"]?.stringValue = "56.0"
        sliders["chrom"]?.doubleValue = chromaticAmount; valueLabels["chrom"]?.stringValue = "2.50"
        sliders["blur"]?.doubleValue = blurRadius; valueLabels["blur"]?.stringValue = "0.0"
        sliders["sat"]?.doubleValue = saturation; valueLabels["sat"]?.stringValue = "1.15"
        sliders["tint"]?.doubleValue = tintOpacity; valueLabels["tint"]?.stringValue = "0.08"
        sliders["edge"]?.doubleValue = edgeHeight; valueLabels["edge"]?.stringValue = "18"
        sliders["rx"]?.doubleValue = rippleStrength; valueLabels["rx"]?.stringValue = "0.42"
        sliders["rf"]?.doubleValue = rippleFrequency; valueLabels["rf"]?.stringValue = "6.0"
        sliders["vy"]?.doubleValue = verticalCurve; valueLabels["vy"]?.stringValue = "0.78"
        layoutGlassLayers()
        applyGlassParameters()
    }

    // MARK: - Preview Page Content

    private func rebuildPreviewPage() {
        previewDocView.subviews.forEach { $0.removeFromSuperview() }
        previewDocView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let w: CGFloat = 780
        previewDocView.frame = NSRect(x: 0, y: 0, width: w, height: 1600)

        if themeIndex == 0 {
            previewDocView.layer?.backgroundColor = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 1).cgColor
            let palette: [NSColor] = [
                NSColor(srgbRed: 0.14, green: 0.44, blue: 0.28, alpha: 1),
                NSColor(srgbRed: 0.84, green: 0.26, blue: 0.20, alpha: 1),
                NSColor(srgbRed: 0.16, green: 0.42, blue: 0.84, alpha: 1),
                NSColor(srgbRed: 0.90, green: 0.62, blue: 0.12, alpha: 1)
            ]
            for i in 0..<8 {
                let card = NSView(frame: NSRect(x: 24 + CGFloat(i % 2) * 365, y: 20 + CGFloat(i / 2) * 190, width: 345, height: 165))
                card.wantsLayer = true
                card.layer?.cornerRadius = 16
                card.layer?.backgroundColor = palette[i % palette.count].cgColor
                let t = NSTextField(labelWithString: "COVER YOUR TRACKS • CARD \(i + 1)")
                t.frame = NSRect(x: 18, y: 20, width: 310, height: 34)
                t.font = .systemFont(ofSize: 20, weight: .black)
                t.textColor = .white
                card.addSubview(t)
                let sub = NSTextField(wrappingLabelWithString: "Scroll this card behind the top bar to see live optical distortion, lens bending, and refraction in real time.")
                sub.frame = NSRect(x: 18, y: 60, width: 310, height: 80)
                sub.font = .systemFont(ofSize: 13.5, weight: .medium)
                sub.textColor = NSColor.white.withAlphaComponent(0.92)
                card.addSubview(sub)
                previewDocView.addSubview(card)
            }
        } else if themeIndex == 1 {
            previewDocView.layer?.backgroundColor = NSColor.white.cgColor
            let nav = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 92))
            nav.wantsLayer = true
            nav.layer?.backgroundColor = NSColor(srgbRed: 0.27, green: 0.27, blue: 0.28, alpha: 1).cgColor
            let navTxt = NSTextField(labelWithString: "   Store   Mac   iPad   iPhone   Watch   AirPods   TV & Home   Support")
            navTxt.frame = NSRect(x: 40, y: 56, width: 700, height: 24)
            navTxt.font = .systemFont(ofSize: 13.5, weight: .medium)
            navTxt.textColor = NSColor.white.withAlphaComponent(0.88)
            nav.addSubview(navTxt)
            previewDocView.addSubview(nav)

            let hero = NSView(frame: NSRect(x: 40, y: 120, width: 680, height: 260))
            hero.wantsLayer = true
            hero.layer?.cornerRadius = 22
            hero.layer?.backgroundColor = NSColor(srgbRed: 0.36, green: 0.14, blue: 0.22, alpha: 1).cgColor
            let hTxt = NSTextField(labelWithString: "iPhone 18 Pro")
            hTxt.frame = NSRect(x: 32, y: 32, width: 500, height: 48)
            hTxt.font = .systemFont(ofSize: 38, weight: .bold)
            hTxt.textColor = .white
            hero.addSubview(hTxt)
            previewDocView.addSubview(hero)
        } else {
            previewDocView.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).cgColor
            let neon: [NSColor] = [.systemCyan, .systemPink, .systemYellow, .systemGreen, .systemPurple]
            for row in 0..<18 {
                for col in 0..<10 {
                    let sq = NSView(frame: NSRect(x: 16 + col * 74, y: 12 + row * 74, width: 58, height: 58))
                    sq.wantsLayer = true
                    sq.layer?.cornerRadius = 12
                    sq.layer?.backgroundColor = neon[(row + col) % neon.count].cgColor
                    previewDocView.addSubview(sq)
                }
            }
        }
    }

    // MARK: - Glass Math & Filters

    private func quintic(_ u: Double) -> Double {
        let c = min(1.0, max(0.0, u))
        return 1.0 - c * c * c * (c * (c * 6.0 - 15.0) + 10.0)
    }

    private func profile(y: Double, h: Double) -> Double {
        let solidEnd = max(0, h - edgeHeight)
        if y <= solidEnd { return 1.0 }
        return quintic((y - solidEnd) / max(1, h - solidEnd))
    }

    private func makeBlurMask(h: Double, rows: Int = 128) -> CGImage? {
        var px = [UInt8](repeating: 0, count: rows * 4)
        for r in 0..<rows {
            let v = UInt8((profile(y: Double(r) / Double(rows - 1) * h, h: h) * 255).rounded())
            px[r*4] = v; px[r*4+1] = v; px[r*4+2] = v; px[r*4+3] = v
        }
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func makeDisplacementMap(h: Double) -> CGImage? {
        let rows = 128, cols = 128
        let solidEnd = max(1.0, h - edgeHeight)
        var px = [UInt8](repeating: 128, count: rows * cols * 4)
        for r in 0..<rows {
            let y = Double(r) / Double(rows - 1) * h
            let fade = profile(y: y, h: h)
            let t = min(1.0, max(0.0, y / solidEnd))
            let topRamp = 1.0 - quintic(min(1.0, (Double(r) / Double(rows - 1)) / 0.22))
            let env = (polarityIndex == 0) ? fade : (topRamp * fade)
            let baseY = (polarityIndex == 1)
                ? env * verticalCurve
                : (cos(t * .pi) * verticalCurve + sin(t * .pi * 2.0) * 0.22) * env
            for c in 0..<cols {
                let u = Double(c) / Double(cols - 1)
                let edgeX = sin(u * .pi)
                let nx = max(-1.0, min(1.0, sin(u * .pi * rippleFrequency + t * .pi) * rippleStrength * edgeX * env))
                let ny = max(-1.0, min(1.0, baseY + cos(u * .pi * 4.0) * (rippleStrength * 0.3) * edgeX * env))
                let idx = (r * cols + c) * 4
                px[idx] = UInt8(max(0, min(255, Int((128.0 + nx * 127.0).rounded()))))
                px[idx + 1] = UInt8(max(0, min(255, Int((128.0 + ny * 127.0).rounded()))))
                px[idx + 2] = 128
                px[idx + 3] = 255
            }
        }
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func makeChromMap(h: Double) -> CGImage? {
        if polarityIndex == 0 { return makeDisplacementMap(h: h) }
        let rows = 128
        var px = [UInt8](repeating: 0, count: rows * 4)
        for r in 0..<rows {
            let u = Double(r) / Double(rows - 1)
            let topRamp = 1.0 - quintic(min(1.0, u / 0.22))
            let v = UInt8((max(0.0, min(1.0, topRamp * profile(y: u * h, h: h))) * 255.0).rounded())
            px[r*4] = 0; px[r*4+1] = v; px[r*4+2] = 0; px[r*4+3] = 255
        }
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func applyGlassParameters() {
        let h = glassBarHeight + edgeHeight
        let isDark = (themeIndex != 0)
        let baseTint: NSColor = isDark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1) : .white

        let useNativeGlass = (modeIndex >= 2)
        if useNativeGlass, #available(macOS 26.0, *), let gv = nativeGlassView as? NSGlassEffectView {
            gv.style = (modeIndex == 2) ? .clear : .regular
            gv.cornerRadius = CGFloat(edgeHeight)
            gv.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            gv.tintColor = baseTint.withAlphaComponent(CGFloat(tintOpacity))
            gv.isHidden = false
            tintLayer.opacity = 0
        } else {
            nativeGlassView?.isHidden = true
            tintLayer.opacity = 1
        }

        // Keep backdropLayer active in ALL modes (including NSGlassEffectView .clear/.regular)
        // so every slider (distortion, chromatic, blur, saturation, ripple, curve) works live!
        backdropLayer.opacity = 1

        let filterCls = NSClassFromString("CAFilter") as! NSObject.Type
        func mk(_ name: String) -> NSObject? {
            filterCls.perform(NSSelectorFromString("filterWithType:"), with: name)?.takeUnretainedValue() as? NSObject
        }

        var filters: [NSObject] = []
        let blurFilter: NSObject? = blurRadius > 0.05 ? {
            let f = mk("variableBlur")
            f?.setValue(blurRadius, forKey: "inputRadius")
            f?.setValue(true, forKey: "inputNormalizeEdges")
            if let m = makeBlurMask(h: h) { f?.setValue(m, forKey: "inputMaskImage") }
            return f
        }() : nil

        let dispFilter: NSObject? = displacementAmount > 0.05 ? {
            let f = mk("displacementMap")
            f?.setValue(displacementAmount, forKey: "inputAmount")
            if let m = makeDisplacementMap(h: h) { f?.setValue(m, forKey: "inputMaskImage") }
            return f
        }() : nil

        let chromFilter: NSObject? = chromaticAmount > 0.05 ? {
            let f = mk("chromaticAberrationMap")
            f?.setValue(chromaticAmount, forKey: "inputAmount")
            if let m = makeChromMap(h: h) { f?.setValue(m, forKey: "inputMaskImage") }
            return f
        }() : nil

        let satFilter: NSObject? = abs(saturation - 1.0) > 0.01 ? {
            let f = mk("colorSaturate")
            f?.setValue(saturation, forKey: "inputAmount")
            return f
        }() : nil

        if modeIndex == 0 {
            if let d = dispFilter { filters.append(d) }
            if let c = chromFilter { filters.append(c) }
            if let b = blurFilter { filters.append(b) }
            if let s = satFilter { filters.append(s) }
        } else {
            if let b = blurFilter { filters.append(b) }
            if let d = dispFilter { filters.append(d) }
            if let c = chromFilter { filters.append(c) }
            if let s = satFilter { filters.append(s) }
        }

        let stops = 12
        var colors: [CGColor] = []
        var locs: [NSNumber] = []
        for i in 0..<stops {
            let loc = Double(i) / Double(stops - 1)
            locs.append(NSNumber(value: loc))
            colors.append(baseTint.withAlphaComponent(CGFloat(tintOpacity * profile(y: loc * h, h: h))).cgColor)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.filters = filters
        tintLayer.colors = colors
        tintLayer.locations = locs
        CATransaction.commit()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = GlassTunerController()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
