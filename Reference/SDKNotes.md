# macOS 27.3 / Xcode 27.2 Verified SDK Signatures

All signatures below are verified directly against `/Applications/Xcode_27.2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` and compiled with `swift`.

## 1. `NSGlassEffectView` & `NSGlassEffectContainerView`
Header: `<AppKit/NSGlassEffectView.h>` (`API_AVAILABLE(macos(26.0))`, `effectIsInteractive` is `macos(27.0)`).

```swift
// Enum: NSGlassEffectView.Style (ObjC: NSGlassEffectViewStyle)
public enum Style : Int {
    case regular = 0 // NSGlassEffectViewStyleRegular
    case clear = 1   // NSGlassEffectViewStyleClear
}

@available(macOS 26.0, *)
open class NSGlassEffectView : NSView {
    /// Place all inner controls inside `contentView` (do NOT add arbitrary subviews directly to NSGlassEffectView).
    open var contentView: NSView?
    open var cornerRadius: CGFloat
    @NSCopying open var tintColor: NSColor?
    open var style: NSGlassEffectView.Style

    @available(macOS 27.0, *)
    open var effectIsInteractive: Bool // default false; set true for interactive toolbar buttons & pills
}

@available(macOS 26.0, *)
open class NSGlassEffectContainerView : NSView {
    /// Contains descendant NSGlassEffectView instances to batch and morph when within `spacing`.
    open var contentView: NSView?
    open var spacing: CGFloat // default 0
}
```

## 2. `NSBackgroundExtensionView`
Header: `<AppKit/NSBackgroundExtensionView.h>` (`API_AVAILABLE(macos(26.0))`).

```swift
@available(macOS 26.0, *)
open class NSBackgroundExtensionView : NSView {
    /// Content view extended behind safe area (titlebar/toolbar/sidebar).
    open var contentView: NSView?
    /// Defaults to true (places contentView in safe area and extends edges).
    /// Set to false if setting contentView frame/constraints manually.
    open var automaticallyPlacesContentView: Bool
}
```

## 3. HDR `NSColor` & `NSScreen` EDR APIs
Header: `<AppKit/NSColor.h>` (`API_AVAILABLE(macos(26.0))`) and `<AppKit/NSScreen.h>`.

> **Important Swift Naming Note**: In `<AppKit/NSColor.h>`, ObjC `standardDynamicRangeColor` is imported into Swift as `standardDynamicRange`!

```swift
// NSColor HDR APIs (macOS 26.0+)
extension NSColor {
    /// `exposure` >= 0; multiplies linear RGB by 2^exposure.
    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, exposure: CGFloat)

    /// `linearExposure` >= 1.0; multiplies linear RGB by linearExposure.
    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, linearExposure: CGFloat)

    /// Reinterprets color with new contentHeadroom (>= 1.0).
    open func byApplyingContentHeadroom(_ contentHeadroom: CGFloat) -> NSColor // ObjC: colorByApplyingContentHeadroom:

    /// Recovers base SDR color if linearExposure > 1.
    @NSCopying open var standardDynamicRange: NSColor { get } // ObjC: standardDynamicRangeColor
}

// NSScreen EDR APIs (macOS 10.11 / 10.15+)
extension NSScreen {
    open var maximumExtendedDynamicRangeColorComponentValue: CGFloat { get }
    open var maximumPotentialExtendedDynamicRangeColorComponentValue: CGFloat { get }
    open var maximumReferenceExtendedDynamicRangeColorComponentValue: CGFloat { get }
}
```

## 4. `CAMetalLayer` & `CAEDRMetadata`
Headers: `<QuartzCore/CAMetalLayer.h>`, `<QuartzCore/CAEDRMetadata.h>`.

```swift
// CAMetalLayer
open var wantsExtendedDynamicRangeContent: Bool // default false
open var edrMetadata: CAEDRMetadata?            // ObjC: EDRMetadata; nil = unclamped up to screen maxEDR
open var pixelFormat: MTLPixelFormat            // use .rgba16Float for EDR
// colorspace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

// CAEDRMetadata
open class var hlg: CAEDRMetadata { get }       // ObjC: HLGMetadata
open class var isAvailable: Bool { get }
```

## 5. `NSButton` macOS 26.0 Glass/Control Properties
Header: `<AppKit/NSButton.h>`:
```swift
@available(macOS 26.0, *)
open var tintProminence: NSTintProminence
@available(macOS 26.0, *)
open var borderShape: NSControl.BorderShape
```
