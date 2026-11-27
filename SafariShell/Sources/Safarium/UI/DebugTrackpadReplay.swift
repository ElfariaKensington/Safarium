import AppKit

/// SAFARIUM_SCROLL_DEBUG=1: scroll/overshoot diagnostics appended to /tmp/safarium-scroll.log
/// (the app's os_log output is not visible in `log show`).
enum ScrollDebugLog {
    private static let file: UnsafeMutablePointer<FILE>? = {
        guard ProcessInfo.processInfo.environment["SAFARIUM_SCROLL_DEBUG"] != nil else { return nil }
        return fopen("/tmp/safarium-scroll.log", "a")
    }()
    static var isEnabled: Bool { file != nil }
    static func write(_ line: String) {
        guard let f = file else { return }
        fputs(line.hasSuffix("\n") ? line : line + "\n", f)
        fflush(f)
    }
}

/// Debug-only (SAFARIUM_SCROLL_DEBUG): synthesizes a 120 Hz precise trackpad gesture and posts it to the app's own
/// event queue. Spec: "<fingerDy> <fingerFrames> <momentumDy0> <decay> [xFrac yFrac]" — fingerDy > 0 scrolls up.
enum DebugTrackpadReplay {
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(sym, to: SetWindowLocation.self)
    }()

    static func run(spec: String, in window: NSWindow) {
        let p = spec.split(separator: " ").compactMap { Double($0) }
        let fingerDy = p.count > 0 ? p[0] : 40
        let fingerFrames = p.count > 1 ? Int(p[1]) : 8
        let mom0 = p.count > 2 ? p[2] : 60
        let decay = p.count > 3 ? p[3] : 0.955
        let xf = p.count > 4 ? p[4] : 0.5
        let yf = p.count > 5 ? p[5] : 0.5

        // (dy, scrollPhase, momentumPhase) in CGEvent field values.
        var steps: [(Double, Int64, Int64)] = [(0, 128, 0), (fingerDy, 1, 0)]
        for _ in 0..<max(0, fingerFrames - 1) { steps.append((fingerDy, 2, 0)) }
        steps.append((0, 4, 0))
        if mom0 != 0 {
            var d = mom0
            steps.append((d, 0, 1))
            while abs(d) >= 0.5 { d *= decay; steps.append((d, 0, 2)) }
            steps.append((0, 0, 3))
        }

        let frame = window.frame
        let screenH = NSScreen.screens.first?.frame.height ?? frame.maxY
        let pt = CGPoint(x: frame.minX + frame.width * xf, y: screenH - (frame.minY + frame.height * (1 - yf)))
        var i = 0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { t in
            guard i < steps.count else { t.invalidate(); return }
            let (dy, ph, mo) = steps[i]; i += 1
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return }
            e.location = pt
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy / 10.0)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: ph)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mo)
            // Raw field 51 is the event's target window number (NSEvent.windowNumber); without it the event has no window.
            if let windowField = CGEventField(rawValue: 51) {
                e.setIntegerValueField(windowField, value: Int64(window.windowNumber))
            }
            e.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9)
            // Window-local point (top-left origin) that AppKit turns into locationInWindow for a window-targeted event.
            setWindowLocation?(e, CGPoint(x: frame.width * xf, y: frame.height * yf))
            if let ev = NSEvent(cgEvent: e) {
                NSApp.postEvent(ev, atStart: false)
            }
        }
        ScrollDebugLog.write("replay \(spec) steps=\(steps.count) at \(pt) win=\(window.windowNumber)")
        RunLoop.main.add(timer, forMode: .common)
    }
}
