import AppKit

/// Fully dynamic adaptive chrome theme derived strictly from the live sampled 3pt top-edge rendered pixels
/// (never `<meta name="theme-color">`). Harmonizes toolbar glass, outer tab track, active tab pill,
/// hairline separator, and foreground contrast dynamically across white, cream, colored, charcoal, and black pages.
struct AdaptiveChromeTheme: Equatable {
    let sampledColor: NSColor
    let relativeLuminance: Double
    let prefersLightInk: Bool

    private var srgb: NSColor {
        sampledColor.usingColorSpace(.sRGB) ?? sampledColor
    }

    var glassTintColor: NSColor? {
        let c = srgb
        if prefersLightInk {
            let isNearBlack = c.redComponent < 0.06 && c.greenComponent < 0.06 && c.blueComponent < 0.06
            return isNearBlack ? nil : c.withAlphaComponent(0.24)
        } else {
            let isNearWhite = c.redComponent > 0.94 && c.greenComponent > 0.94 && c.blueComponent > 0.94
            return isNearWhite ? nil : c.withAlphaComponent(0.16)
        }
    }

    var primaryInkColor: NSColor {
        prefersLightInk
            ? NSColor.white.withAlphaComponent(0.94)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.88)
    }

    var secondaryInkColor: NSColor {
        prefersLightInk
            ? NSColor.white.withAlphaComponent(0.76)
            : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.72)
    }

    var disabledInkColor: NSColor {
        prefersLightInk
            ? NSColor.white.withAlphaComponent(0.30)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.28)
    }

    /// Translucent recessed 36pt tab track groove matching real macOS 27.3 Safari (`frame_0005.png`):
    /// lets the frosted toolbar surface breathe through while softly framing the Liquid Glass active pill.
    var tabTrackBackgroundColor: NSColor {
        if prefersLightInk {
            return NSColor.white.withAlphaComponent(0.10)
        } else {
            return NSColor.black.withAlphaComponent(0.055)
        }
    }

    var tabTrackBorderColor: NSColor {
        if prefersLightInk {
            return NSColor.white.withAlphaComponent(0.08)
        } else {
            return NSColor.black.withAlphaComponent(0.055)
        }
    }

    /// Dynamically adapts the elevated 31pt inner active tab pill to the live sampled page top-edge color:
    /// - Pure white `#FFFFFF` -> pure crisp `#FFFFFF`
    /// - Colored light pages -> bright crisp surface subtly tinted by page hue
    /// - Pure black `#000000` -> exact subtle `#2A2A2A` (+0.037 over `#212121` track)
    /// - Colored/charcoal dark pages -> subtly lifted dark surface matching page hue
    var activeTabFillColor: NSColor {
        let c = srgb
        if prefersLightInk {
            return c.blended(withFraction: 0.06, of: .white) ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
        } else {
            let isNearWhite = c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95
            if isNearWhite { return .white }
            return c.blended(withFraction: 0.82, of: .white) ?? .white
        }
    }

    var tabDividerColor: NSColor {
        prefersLightInk
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.16)
    }

    var toolbarBottomHairlineColor: NSColor {
        prefersLightInk
            ? .clear
            : NSColor.black.withAlphaComponent(0.06)
    }

    var topChromeWashColor: NSColor {
        let c = srgb
        let isNearWhite = !prefersLightInk && c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95
        if isNearWhite { return .clear }
        return c.withAlphaComponent(prefersLightInk ? 0.16 : 0.10)
    }

    var preferredAppearance: NSAppearance? {
        NSAppearance(named: prefersLightInk ? .darkAqua : .aqua)
    }

    static let defaultDark = AdaptiveChromeTheme(
        sampledColor: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
        relativeLuminance: 0.0,
        prefersLightInk: true
    )

    static let defaultLight = AdaptiveChromeTheme(
        sampledColor: .white,
        relativeLuminance: 1.0,
        prefersLightInk: false
    )
}

/// Computes `AdaptiveChromeTheme` from top-edge color samples with WCAG relative luminance hysteresis.
final class AdaptiveChromeController {
    private(set) var currentTheme: AdaptiveChromeTheme = .defaultLight
    var onThemeDidChange: ((AdaptiveChromeTheme, Bool) -> Void)?

    private var hasAppliedSample: Bool = false

    func apply(sample: TopEdgeColorSample, animated: Bool = true) {
        let lum = sample.relativeLuminance
        let nextLightInk: Bool
        if currentTheme.prefersLightInk {
            nextLightInk = lum <= SafariMetrics.luminanceSwitchToDarkInkThreshold
        } else {
            nextLightInk = lum < SafariMetrics.luminanceSwitchToLightInkThreshold
        }

        // Skip redundant CATransactions when color & luminance state did not meaningfully change
        if hasAppliedSample && nextLightInk == currentTheme.prefersLightInk {
            let prev = currentTheme.sampledColor.usingColorSpace(.sRGB) ?? currentTheme.sampledColor
            let next = sample.color.usingColorSpace(.sRGB) ?? sample.color
            let dr = abs(prev.redComponent - next.redComponent)
            let dg = abs(prev.greenComponent - next.greenComponent)
            let db = abs(prev.blueComponent - next.blueComponent)
            if max(dr, max(dg, db)) < 0.004 {
                return
            }
        }
        hasAppliedSample = true

        let nextTheme = AdaptiveChromeTheme(
            sampledColor: sample.color,
            relativeLuminance: lum,
            prefersLightInk: nextLightInk
        )
        currentTheme = nextTheme
        onThemeDidChange?(nextTheme, animated)
    }
}
