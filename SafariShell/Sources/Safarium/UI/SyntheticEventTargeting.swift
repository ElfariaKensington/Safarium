import AppKit

/// Gives a synthesized CGEvent a target window and window-local location, so `NSEvent(cgEvent:)` produces an event
/// whose `window` and `locationInWindow` are right (otherwise it has no window and a screen-space location).
enum SyntheticEventTargeting {
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// SkyLight's CGEventSetWindowLocation (window-local, top-left origin). Optional: without it AppKit falls back
    /// to the window's top-left corner for the location.
    private static let setWindowLocation: SetWindowLocation? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(sym, to: SetWindowLocation.self)
    }()
    /// Raw CGEvent field 51 holds the target window number (what NSEvent.windowNumber reads).
    private static let windowNumberField = CGEventField(rawValue: 51)

    static var canSetLocation: Bool { setWindowLocation != nil }

    /// `pointInWindow` is in AppKit window coordinates (bottom-left origin).
    static func target(_ event: CGEvent, window: NSWindow, pointInWindow: NSPoint) {
        guard let field = windowNumberField, let setLocation = setWindowLocation else { return }
        event.setIntegerValueField(field, value: Int64(window.windowNumber))
        setLocation(event, CGPoint(x: pointInWindow.x, y: window.frame.height - pointInWindow.y))
    }
}
