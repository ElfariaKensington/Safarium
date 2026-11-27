import AppKit

/// Honours System Settings → Accessibility → Display → Reduce Motion for Safarium's decorative animations.
enum MotionPreference {
    /// True when the user asked the system to reduce motion; decorative transitions should then jump to their end state.
    nonisolated(unsafe) static var overrideForTesting: Bool?
    static var reduced: Bool { overrideForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
