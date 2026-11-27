import AppKit

/// Exact 1:1 macOS 27.3 Safari layout & visual metrics verified live against `/Applications/Safari.app`
/// at `1200 × 800 pt` (`Reference/VisualDiffAudit.md` + `Reference/Screenshots/comparisons/strip_01..05`).
enum SafariMetrics {
    // MARK: - Window & Unified Toolbar Chrome
    static let windowCornerRadius: CGFloat = 26.0
    static let defaultWindowWidth: CGFloat = 1200.0
    static let defaultWindowHeight: CGFloat = 800.0
    static let minWindowWidth: CGFloat = 680.0
    static let minWindowHeight: CGFloat = 460.0

    /// Exact native macOS 27.3 unified NSToolbar height (`y = 0..52 pt`) + 0.5pt bottom hairline.
    static let toolbarHeight: CGFloat = 48.0 // controls at y = 8..44 (8 pt above, 4 pt below + the soft scroll edge)
    static let backgroundExtensionBleedHeight: CGFloat = 52.0

    // MARK: - Native Traffic Lights (owned by unified NSToolbar: 16x16pt at x=18, 41, 64; y=18; 23pt pitch)
    static let trafficLightTrailingEdge: CGFloat = 80.0

    // MARK: - Unified Equal-Height Liquid Glass Capsules & Tab Track (`36 pt` tall, `18 pt` radius, `y = 8..44`)
    static let glassButtonSize: CGFloat = 36.0
    static let glassButtonCornerRadius: CGFloat = 18.0
    static let glassButtonTopInset: CGFloat = 8.0
    static let glassContainerMergeSpacing: CGFloat = 0.0

    static let leftGroup1StartX: CGFloat = 95.0
    static let sidebarCapsuleWidth: CGFloat = 62.0
    static let backButtonWidth: CGFloat = 36.0
    static let backForwardCapsuleWidth: CGFloat = 72.0
    static let leftGroupInterGap: CGFloat = 7.0
    static let rightCapsuleWidth: CGFloat = 148.0
    static let rightGroupTrailingMargin: CGFloat = 8.0

    // MARK: - Unified Address Bar & Multi-Tab Track (exact 36 pt outer track, 31 pt inner active pill inset 2.5 pt)
    static let tabBarTopInset: CGFloat = 8.0
    static let tabPillHeight: CGFloat = 36.0
    static let tabPillCornerRadius: CGFloat = 18.0
    static let tabInnerInset: CGFloat = 2.5
    static let tabInnerHeight: CGFloat = 31.0
    static let tabInnerCornerRadius: CGFloat = 15.5
    static let tabPillSpacing: CGFloat = 0.0
    static let activePillMinWidth: CGFloat = 220.0
    static let activePillSingleTabWidth: CGFloat = 290.0
    static let activePillSingleTabSidebarWidth: CGFloat = 280.0
    static let activePillFocusedMinWidth: CGFloat = 360.0
    static let activePillFocusedMaxWidth: CGFloat = 520.0
    static let inactiveTabMinWidth: CGFloat = 80.0
    static let fieldIconSize: CGFloat = 16.0
    static let fieldIconBadgeSize: CGFloat = 20.0
    static let addressFieldHeight: CGFloat = 28.0
    static let assistantButtonWidth: CGFloat = 22.0
    static let assistantButtonHeight: CGFloat = 28.0

    // MARK: - Vibrant Split Sidebar (`240 pt` wide, `0.5 pt` divider, `72×36` header capsule, `32 pt` rows)
    static let sidebarDefaultWidth: CGFloat = 240.0
    static let sidebarMinWidth: CGFloat = 200.0
    static let sidebarMaxWidth: CGFloat = 320.0
    static let sidebarHeaderCapsuleWidth: CGFloat = 72.0
    static let sidebarRowHeight: CGFloat = 32.0

    // MARK: - Top-Edge Sampling & Contrast Hysteresis
    static let topEdgeStripHeight: CGFloat = 3.0
    static let luminanceSwitchToLightInkThreshold: Double = 0.42
    static let luminanceSwitchToDarkInkThreshold: Double = 0.52
    static let topEdgeSampleDebounceInterval: TimeInterval = 0.045
    static let topEdgeTintAnimationDuration: TimeInterval = 0.22

    // MARK: - Subtle Refined HDR / EDR Lift for Active Tab Pill
    static func activeTabLinearExposure(for screen: NSScreen?) -> CGFloat {
        activeTabLinearExposure(headroom: screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    static func activeTabLinearExposure(headroom rawHeadroom: CGFloat) -> CGFloat {
        let headroom = max(1.0, rawHeadroom)
        guard headroom > 1.02 else { return 1.0 }
        return min(1.07, 1.0 + 0.042 * min(headroom - 1.0, 1.6))
    }

    static func accentLinearExposure(for screen: NSScreen?) -> CGFloat {
        accentLinearExposure(headroom: screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    static func accentLinearExposure(headroom rawHeadroom: CGFloat) -> CGFloat {
        let headroom = max(1.0, rawHeadroom)
        guard headroom > 1.02 else { return 1.0 }
        return min(1.10, 1.0 + 0.06 * min(headroom - 1.0, 1.5))
    }
}
