# Safarium Zero-Flicker Navigation Architecture & Implementation Plan

## 1. Architectural Reflection: Why Web Navigation Flickers

Every visible "seam" during browser navigation comes down to a single invariant violation: **the window compositor presents at least one display refresh where neither the outgoing visual state nor the settled incoming visual state owns the viewport pixels.**

Modern browser engines attack this gap at different layers, yet each engine primitive covers only a narrow slice of real-world browsing:

- **Compositor Commit Deferral ([Chromium Paint Holding](https://developer.chrome.com/blog/paint-holding))**: Defers impl-thread compositor commits after navigation commit until a page load signal (First Contentful Paint or a short ~500ms timeout) arrives. While effective for fast same-origin clicks, it drops the old surface once the timeout expires, does not cover native-UI-to-web transitions (`safarium://start` to `https://...`), and cannot mask cross-process surface eviction if the incoming renderer has not produced a `LocalSurfaceId` frame yet.
- **Full-Page Heap & Renderer Preservation ([Back/Forward Cache](https://web.dev/articles/bfcache))**: Freezes the outgoing DOM, layout tree, and JavaScript heap in memory for instant history restores (`pageshow` with `event.persisted === true`). However, real-world sessions still miss BFCache due to `Cache-Control: no-store`, active IndexedDB/WebLocks transactions, `window.opener` references, renderer memory pressure, or session/tab restore.
- **Declarative & Same-Origin Morphing ([Cross-Document View Transitions](https://developer.chrome.com/docs/web-platform/view-transitions/cross-document) & [WebKit Crossfade Design](https://webkit.org/blog/16967/two-lines-of-cross-document-view-transitions-code-you-can-use-on-every-website-today/))**: Snapshots outgoing elements before the last frame (`pageswap`), suppresses rendering while the new DOM initializes (`pagereveal` + `<link rel="expect" blocking="render">`), and runs a `mix-blend-mode: plus-lighter` isolated dissolve ([Same-Document & UA Visual Transitions](https://developer.chrome.com/docs/web-platform/view-transitions/same-document)). Because `@view-transition { navigation: auto; }` is strictly opt-in and restricted to same-origin navigations without cross-origin redirects, a browser shell cannot rely on websites opting in—and must also respect `NavigateEvent.hasUAVisualTransition` ([Chromium Issue 442161286](https://issues.chromium.org/issues/442161286)) so shell swipe transitions never double-animate over author View Transitions.
- **Background Tab & Prerender Activation ([Speculation Rules API](https://developer.chrome.com/docs/web-platform/prerender-pages))**: Eliminates network/parse latency by prerendering high-confidence omnibox, bookmark-hover, and `<script type="speculationrules">` targets inside hidden MPArch trees, activating them in near-zero LCP.
- **Compositor Eviction & Native Parent Background Bugs ([Chromium Issue 335289](https://bugs.chromium.org/p/chromium/issues/detail?id=335289), [Chromium Issue 40424669](https://issues.chromium.org/issues/40424669), [CEF Issue #3891](https://github.com/chromiumembedded/cef/issues/3891))**: When a tab is backgrounded or swapped across origins, tile/IOSurface eviction can stall the UI compositor up to its 66ms deadline before drawing a fallback canvas. Worse, in CEF's Chrome runtime (`ChromeBrowserHostImpl::CreateBrowser`), `contents_web_view()->SetBackgroundVisible(false)` causes `ContentsWebView::UpdateBackgroundColor` to call `RenderWidgetHostView::SetBackgroundColor(SK_ColorTRANSPARENT)` on `RenderViewReady`—wiping out `CefBrowserSettings.background_color` and exposing whatever raw CALayer backdrop sits behind the host view.

**Core Design Thesis for Safarium**: Because Safarium owns **both** the native AppKit compositor (`SafariShell`) and the ObjC++ CEF/Chromium 156 bridge (`BrowserCore`), it can enforce a **strict composited freeze-frame invariant** above Chromium's `RenderWidgetHostViewCocoa`: *no navigation, history jump, native-page exit, or tab switch ever exposes an unpainted or evicted web surface until the incoming surface has painted non-blank content (or an explicit bounded budget cleanly crossfades into a theme-matched canvas).*

---

## 2. Audit of Exact Flicker Root Causes in `/Users/elfaria/SafariX`

Inspection of [SafariShell](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium) and [BrowserCore](file:///Users/elfaria/SafariX/BrowserCore/src) uncovered eight concrete seams:

| ID | Seam / Flicker Vector | Exact Code Location | Why It Flashes Today |
| :--- | :--- | :--- | :--- |
| **G1** | **Native-to-Web & Web-to-Native Cut** (`safarium://start`, `history`, `inspect` to Web) | [ChromiumBrowserEngine.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/Engine/ChromiumBrowserEngine.swift) (`loadURL`, lines 586–599) & [SafariWindowController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SafariWindowController.swift) (`performActiveTabNavigation`, lines 2190–2199) | While on Start Page, `SXBrowserTab` sits hidden at `about:blank`. Clicking a Favorite immediately sets `nativePageMode = .none` and hides `startPageView`, exposing `about:blank` / unpainted `RenderWidgetHostViewCocoa` for 100–800ms before first paint. |
| **G2** | **CEF Chrome Runtime `SK_ColorTRANSPARENT` Reset & Stale Backdrop Bleed** | [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (lines 1458–1467) & [SafariWindowController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SafariWindowController.swift) | Per [CEF Issue #3891](https://github.com/chromiumembedded/cef/issues/3891), `RenderViewReady` resets the renderer base background to `SK_ColorTRANSPARENT`, bleeding `mainPaneView` / `extensionBackdropFill` (which still holds the *previous* site's sampled header color) and ignoring live macOS Light/Dark appearance switches. |
| **G3** | **Toolbar Button & Shortcut Back/Forward Bypass Snapshot Shield** | [SafariWindowController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SafariWindowController.swift) (`navigateBackInActiveTab` / `navigateForwardInActiveTab`, lines 2567–2579; 3-finger `.swipe`, lines 1970–1976) | Only 2-finger trackpad pans go through [SwipeNavigationController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SwipeNavigationController.swift). Clicking `<`/`>`, pressing `Cmd+[` / `Cmd+]`, or 3-finger swiping invokes `tab.goBack()` raw—flashing on BFCache misses, cross-origin swaps, or `about:blank` Start Page hops. |
| **G4** | **Premature `sx.nav_ready` Before Stylesheets, Fonts, or FCP** | [SXHelperMain.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXHelperMain.mm) (`reportNavReady`, lines 1697–1718) | Fires `reportNavReady(false)` on `DOMContentLoaded` + two `requestAnimationFrame` ticks even if render-blocking `<link rel="stylesheet">` sheets are still pending or zero contentful pixels (`first-contentful-paint`) have painted. |
| **G5** | **Cold Background Tab Switch Eviction Blink** | [SafariWindowController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SafariWindowController.swift) (`selectTab(at:)`, lines 2581–2660) | Synchronously hides the old tab and unhides the incoming `SXBrowserHostView`. When Chromium has evicted the background tab's `IOSurface` ([Chromium Issue 335289](https://bugs.chromium.org/p/chromium/issues/detail?id=335289)), 1–3 blank frames appear while Viz surface sync round-trips, even though `tab.cachedSnapshot` is already in RAM. |
| **G6** | **Network Prediction & Speculation Globally Disabled** | [SXApp.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXApp.mm) (line 228) & [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (line 935) | `--disable-features=...NetworkPrediction` and `net.network_prediction_options = 2` (`NETWORK_PREDICTION_NEVER`) kill Speculation Rules `prefetch`/`prerender` and preconnect across normal windows, adding 150–500ms of avoidable network latency on every click. |
| **G7** | **Two-Step Toolbar & Theme Color Jump Mid-Navigation** | [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (`loadURL:`, lines 1538–1549) & [SXTopEdgeColorSampler.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXTopEdgeColorSampler.mm) (lines 285–311) | `self.fixedHeaderColor = nil` clears immediately at `loadURL:` *before* commit, while `sx.page_bg`, `sx.fixed_header`, and `SXTopEdgeColorSampler` arrive asynchronously across `OnLoadStart` and `OnLoadEnd`, causing multi-step toolbar tint snaps. |
| **G8** | **Double Main-Queue Async Hop & 33ms Idle Pump Latency** | [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (`scheduleMessagePumpWorkWithDelayMs:`, lines 1775–1835) | `delayMs <= 0` schedules *two* nested `dispatch_async(dispatch_get_main_queue(), ...)` hops, and idle heartbeat drops to 33ms (30Hz), adding run-loop turn jitter during 120Hz ProMotion navigation commits. |

---

## 3. Target Architecture: Unified `NavigationTransitionCoordinator`

Instead of scattering transition logic across `SwipeNavigationController`, `SafariWindowController`, and `SXBrowserTab`, we introduce a single AppKit compositor state machine—**`NavigationTransitionCoordinator`**—paired with upgraded readiness and color-commit signals in `BrowserCore`.

### 3.1 State Machine & Freeze-Frame Contract
`NavigationTransitionCoordinator` sits in `mainPaneView` directly above `webContentHost`, `startPageView`, `historyPageView`, and `inspectPageView` (and below floating popovers/find bar):

1. **`idle`**: Zero overlay views in the render tree (`isHidden = true`, `contents = nil`), zero GPU overdraw.
2. **`interactiveSwipe(direction, progress)`**: Driven by `SwipeNavigationController` at 120Hz. Uses prewarmed `NavigationSnapshotStore` `CGImage` layers with 22% parallax and edge shadow.
3. **`holdingVeil(kind, token, deadline)`**: Entered atomically **before** any mutating navigation call (`loadURL`, `goBack`, `goForward`, `selectTab`):
   - **Native-to-Web (`startPage` / `history` / `inspect` -> Web)**: Captures a 1x/2x `IOSurface`-backed layer snapshot of the outgoing native view (`cacheDisplay` / `CALayer` render) and keeps `startPageView` visually frozen in the veil while `sxTab.setTabActive(true)` and `sxTab.load(url)` warm up underneath. Only when `didBecomeVisuallyReadyForNavigation` fires (or a `450ms` perceptual cap is reached, transitioning smoothly to a skeleton-free theme-matched canvas with toolbar progress bar) does the veil dissolve over `110ms` (`CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)`).
   - **Discrete History Jump (Toolbar `<`/`>`, `Cmd+[` / `Cmd+]`, 3-finger `.swipe`)**: Checks `NavigationSnapshotStore.shared.image(tabID:entryID:)` for `previousNavigationEntryID` / `nextNavigationEntryID`.
     - If cached snapshot exists: immediately presents the destination snapshot (or a subtle `90ms` directional micro-dissolve honoring `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`) while `tab.goBack()` / `tab.goForward()` restores BFCache or loads underneath, holding the target snapshot until `didBecomeVisuallyReadyForNavigation` confirms live pixels match! That eliminates both the `about:blank` hop when returning to `safarium://start` and cross-origin renderer swap flashes.
     - If no target snapshot exists: freezes the outgoing frame for up to `280ms` (extending Paint Holding seamlessly across cross-origin swaps) before crossfading.
   - **Cold Tab Switch (`selectTab(at:)`)**: If the incoming web tab has been backgrounded longer than `3.0s` and has a `tab.cachedSnapshot`, `NavigationTransitionCoordinator` pins `cachedSnapshot` over `webContentHost` on frame 0 of `selectTab(at:)`, requests an immediate compositor frame (`wasShown` / `SXTopEdgeColorSampler` check), and drops the shield on the next synchronized paint (`<= 80ms`), eliminating evicted-surface white/black blinks.
4. **`revealing(duration)`**: Runs a GPU-composited opacity dissolve (`CAAnimation` on `CALayer.opacity`) synchronized with `chromeController` toolbar tint commit in a single `NSAnimationContext` transaction.

---

## 4. Concrete File-by-File Implementation Plan

### Phase 1: `NavigationTransitionCoordinator` & Universal Freeze-Frame Shield (`SafariShell`)
- **New File — `SafariShell/Sources/Safarium/UI/NavigationTransitionCoordinator.swift`**:
  - Owns a lightweight, non-hit-testing (`hitTest -> nil`) `NSView` (`wantsLayer = true`, `layerContentsRedrawPolicy = .never`) hosting an outgoing/incoming `CALayer` pair.
  - Exposes:
    - `beginNativeToWebTransition(from nativeView: NSView, tabID: UUID, expectedDarkCanvas: Bool)`
    - `beginProgrammaticHistoryTransition(direction: Direction, outgoingView: NSView, targetSnapshot: NavigationSnapshotPayload?, tabID: UUID)`
    - `beginTabSwitchShieldIfNeeded(for incomingTab: BrowserTabEngine)`
    - `notifyVisuallyReady(tabID: UUID, fromBFCache: Bool, pendingChromeSample: TopEdgeColorSample?)`
    - `cancel(tabID: UUID)`
  - Respects `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (switches any micro-slide to a pure `80ms` opacity dissolve per [WebKit's motion-safe crossfade guidance](https://webkit.org/blog/16967/two-lines-of-cross-document-view-transitions-code-you-can-use-on-every-website-today/)).
- **Modify — [SwipeNavigationController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SwipeNavigationController.swift)**:
  - Delegate post-commit snapshot holding (`isAwaitingCommittedPagePaint`) to `NavigationTransitionCoordinator` or share the unified generation token so rapid mid-transition gestures/shortcuts cancel cleanly without orphaned overlays.
  - Set `hasUAVisualTransition` awareness: expose a renderer hint (`window.__sxSwipeTransitionActive`) during trackpad swipe commits so pages checking UA visual transitions do not double-play SPA animations.
- **Modify — [SafariWindowController.swift](file:///Users/elfaria/SafariX/SafariShell/Sources/Safarium/UI/SafariWindowController.swift)**:
  - In `performActiveTabNavigation(to:)` (line 2180): when `tab.isNativeInternalPage` transitions to a web URL, call `transitionCoordinator.beginNativeToWebTransition(...)` *before* `tab.load(url:)` and `updateStartPageVisibility()`.
  - In `navigateBackInActiveTab()` & `navigateForwardInActiveTab()` (lines 2567–2579): look up `NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: targetEntryID)` and call `transitionCoordinator.beginProgrammaticHistoryTransition(...)` before `tab.goBack()` / `tab.goForward()`.
  - In `selectTab(at:)` (line 2581): track `lastBackgroundedAt: [UUID: CFTimeInterval]` per tab; if backgrounded `> 3.0s` and `!tab.isNativeInternalPage`, invoke `transitionCoordinator.beginTabSwitchShieldIfNeeded(for: tab)`.

### Phase 2: Opaque Pre-Paint Base Canvas & Atomic Toolbar Theme Commit (`BrowserCore` + `SafariShell`)
- **Modify — [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) & [SXBrowserClient.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXBrowserClient.mm)**:
  - **Fix [CEF Issue #3891](https://github.com/chromiumembedded/cef/issues/3891) Transparent Base Canvas**:
    1. Keep `SXBrowserHostView.layer.backgroundColor` and `mainPaneView` web backdrop strictly bound to the current neutral system/page-scheme base color (`#1C1C1E` in Dark Mode / Private Mode, `#FFFFFF` in Light Mode)—**never** tint the underlying `webContentHost` backing layer with the previous domain's vibrant header color (`extensionBackdropFill` is restricted strictly to the top overscroll pocket above `y = 0`!).
    2. On `OnLoadingStateChange` / `OnLoadStart` (main frame) and on `NSApplication` effectiveAppearance KVO changes, push `DevTools` `Emulation.setDefaultBackgroundColorOverride` (with opaque alpha `a: 255` matching current `prefersDarkAppearance`) AND update `SXBrowserHostView` layer background synchronously so new cross-origin `RenderWidgetHostViewCocoa` instances never flash white in Dark Mode or dark in Light Mode.
  - **Atomic Chrome Theme Commit (Fix G7)**:
    - Stop nil-ing `self.fixedHeaderColor = nil` prematurely inside `loadURL:` (lines 1538–1549). Instead, mark the existing theme color as `pendingNavigationReset = YES` and hold the toolbar's current `ToolbarGlassView` / `ChromeController` appearance while the outgoing veil is visible.
    - Buffer incoming `sx.page_bg`, `sx.fixed_header`, and initial `SXTopEdgeColorSampler` samples during provisional load, then apply the winning sample **once** inside the same `NSAnimationContext` transaction as `transitionCoordinator.notifyVisuallyReady(...)`. Result: toolbar glass and page viewport crossfade in lockstep—zero double-tinting.

### Phase 3: True FCP + Stylesheet/Font-Settled `sx.nav_ready` v2 (`BrowserCore`)
- **Modify — [SXHelperMain.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXHelperMain.mm) (lines 1697–1720)**:
  - Upgrade `installNavigationReadyProbe` from naive `DOMContentLoaded + 2 rAF` to a multi-signal readiness gate (`sx.nav_ready` v2):
    1. **BFCache Fast Path (`pageshow` with `ev.persisted === true`)**: Fire `reportNavReady(true)` after a single `requestAnimationFrame` (< 8.3ms at 120Hz).
    2. **Prerender Activation Fast Path (`prerenderingchange` or `activationStart > 0`)**: Fire `reportNavReady(true)` immediately on first `rAF`.
    3. **Cross-Document View Transition Path (`pagereveal` with `ev.viewTransition != null`)**: Wait for `ev.viewTransition.ready` (with a `120ms` fallback) so Chromium's native `@view-transition { navigation: auto; }` snapshot pair starts seamlessly as our shell veil lifts.
    4. **Fresh Document Load Path**: Wait for **all** of:
       - `PerformanceObserver` observing `paint` (`first-contentful-paint`) OR non-empty body layout (`document.body && document.body.getBoundingClientRect().height > 0`),
       - Pending `<head>` render-blocking `<link rel="stylesheet">` sheets settled (bounded by a `180ms` stylesheet grace cap),
       - `Promise.race([document.fonts.ready, timeout(60)])` to prevent FOUT layout-jump flicker on cached web fonts,
       - Followed by 1 post-paint `requestAnimationFrame`—all bounded by a hard `400ms` max readiness budget after commit so slow streaming pages still reveal progressively without feeling stuck.
  - Also pass the computed root/body background RGB (`getComputedStyle(document.documentElement).backgroundColor` / `body`) inside the `sx.nav_ready` payload so `SafariShell` has an exact initial backdrop color before `Page.captureScreenshot` completes.

### Phase 4: Privacy-Safe Speculation, Hover Prewarming & 120Hz Single-Hop CEF Pump
- **Modify — [SXApp.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SXApp.mm) (line 228) & [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (line 935)**:
  - Remove `NetworkPrediction` from `--disable-features` in `SXApp.mm` (keeping `OptimizationHints,Translate,MediaRouter` disabled).
  - Scope `net.network_prediction_options`:
    - **Private / Incognito profiles (`isIncognito == YES`) or when `BrowserSettings.preloadTopHit == false`**: Keep `2` (`NETWORK_PREDICTION_NEVER`) so zero speculative packets leave in Private Browsing.
    - **Standard profile (default)**: Set `0` (`NETWORK_PREDICTION_ALWAYS` / Wi-Fi+Ethernet standard prediction) and enable `Prerender2` + Speculation Rules (`prefetch` and `prerender` with Chrome's conservative 2-slot FIFO memory cap per [Chrome Speculation Rules limits](https://developer.chrome.com/docs/web-platform/prerender-pages)).
  - **Native UI Intent Prewarming (`SafariShell` -> `BrowserCore`)**:
    - Add `prewarmOrigin(_ url: URL)` on `BrowserTabEngine` / `SXBrowserTab` (using lightweight DNS/TLS preconnect via Chromium's `NetworkContext` or `<link rel="preconnect">` in the hidden `about:blank` warm frame).
    - Trigger `prewarmOrigin` when hovering a Start Page Favorite tile for `>= 140ms` or when the top autocomplete Top Hit stabilizes in `CompactTabAddressBar`. By the time the user clicks (`~200–350ms` later), DNS + TLS 1.3 handshake is already warm!
- **Modify — [SafariumEngineBridge.mm](file:///Users/elfaria/SafariX/BrowserCore/src/SafariumEngineBridge.mm) (lines 1775–1835)**:
  - Collapse the double `dispatch_async(dispatch_get_main_queue(), ...)` inside `scheduleMessagePumpWorkWithDelayMs:0` into a single coalesced `CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ...)` + `CFRunLoopWakeUp`, and tighten active-navigation pump cadence from `33ms` to `8ms` (120Hz) for `500ms` following any navigation start (`notifyNavigationStarted`), dropping back to `33ms` once idle to preserve battery.

---

## 5. Multi-Tier Verification & Zero-Flicker Test Plan

Safarium already has **1,945 passing XCTests** (`HermeticTestCase`), offscreen `VisualSnapshotTests`, and live `mcu` / headless Chromium probes documented in [QA-REPORT.md](file:///Users/elfaria/SafariX/QA-REPORT.md). We will add four targeted test layers so "no flicker" is mathematically asserted rather than judged by eye alone:

### Layer 1: Deterministic State-Machine & Luminance-Continuity XCTests (`SafariShell/Tests/SafariumTests/NavigationContinuityTests.swift`)
- **Native-to-Web Veil Hold Test**: Drive `SafariWindowController(engine: MockBrowserEngine())` from `safarium://start` -> `https://dark.example.com`. Sample the offscreen `mainPaneView` bitmap (`VisualSnapshotTests.image(of:)`) at every intermediate step:
  1. Before `loadURL` (Start Page visible),
  2. Immediately after `loadURL` *before* `didBecomeVisuallyReadyForNavigation` fires,
  3. Mid-dissolve (`50ms`),
  4. Post-reveal.
  - **Assertion**: Zero frames equal raw white (`#FFFFFF`) or `about:blank` while in Dark Mode; frame-to-frame mean relative luminance (`SXRelativeLuminanceSRGB`) moves monotonically between Start Page luminance and destination luminance with **zero spike > 0.05** outside the `[min(L_src, L_dst), max(L_src, L_dst)]` envelope!
- **Keyboard & Toolbar Back/Forward Parity Test**: Populate `NavigationSnapshotStore` with known colored snapshots for Entry A (blue), Entry B (amber), and Start Page (`-1`), trigger `navigateBackInActiveTab()` and `navigateForwardInActiveTab()`, and assert the target snapshot shields `webContentHost` until `didBecomeVisuallyReadyForNavigation` completes.
- **Cold Tab Switch Shield Test**: Simulate 2 tabs where Tab 0 was backgrounded `> 3.0s` with a `cachedSnapshot`; call `selectTab(at: 0)` while `MockTab` delays live paint by `60ms`, asserting `mainPaneView` renders `cachedSnapshot` on frame 0 with zero blank flash.
- **Atomic Chrome Tint Test**: Verify `chromeController` and `toolbarFrostView` mutate at most **once** per committed navigation (no intermediate reset to default gray followed by re-tint).

### Layer 2: `SXHelperMain` Readiness Probe Unit & Torture Matrix (`NavigationReadyProbeTests.swift` + Local HTTP Delay Server)
- Spin up a hermetic `NWListener` / Python loopback HTTP server in tests serving controlled torture pages:
  1. **Slow CSS Page**: HTML arrives in `5ms`, `<link rel="stylesheet" href="/slow.css">` (sets `background: #0d1117; color: #fff`) delayed by `150ms`. Verify `sx.nav_ready` waits for `/slow.css` so the unstyled white HTML flash is never revealed!
  2. **Slow TTFB Cross-Origin Page (`700ms` delay — exceeds Chromium's 500ms Paint Holding cap)**: Verify `NavigationTransitionCoordinator` holds the outgoing veil / progress state smoothly without dropping to a raw white/transparent surface at `t = 501ms`.
  3. **BFCache Instant Restore Page**: Navigate Page A -> Page B -> Back; verify `fromBFCache == true` and total reveal latency `< 90ms`.
  4. **Cross-Document View Transition Page (`@view-transition { navigation: auto; }`)**: Navigate Page 1 -> Page 2 same-origin; verify `sx.nav_ready` aligns with `pagereveal` and zero double-slide occurs on swipe back.

### Layer 3: Multi-Suite Regression & App-Bundle Verification (`SafariumTests` + `Safarium.app`)
- Compile `BrowserCore` (`libSafariumBrowserCore.dylib` + 5 `Safarium Helper*.app` bundles) and `SafariShell` (`arm64`), then run `NavigationContinuityTests` alongside `SwipeNavigationTests`, `MockBrowserEngineTests`, `TopEdgeColorSamplerTests`, `StartPageViewTests`, and `WindowTabLifecycleTests` across all 6 navigation invariants:
  1. Start Page Favorite click to Dark site (`#0d1117`) holding the Start Page snapshot with monotonic viewport luminance (`|ΔL| <= 0.06` during load),
  2. Programmatic Back (`Cmd+[` / `<`) and Forward (`Cmd+]` / `>`) snapshot shielding and teardown,
  3. Two-finger trackpad swipe commit handoff (`settleTimer` armed prior to `onCommitNavigation`) without duplicate programmatic veil stacking,
  4. Exact `52pt` unified toolbar snapshot registration (`y = 0..696` web vs `y = 0..748` full-bleed native) with zero vertical jump,
  5. Cold background tab switch (`>= 2.5s`) Viz surface-sync shield vs zero-overhead warm tab switch,
  6. Start Page Favorite hover/mousedown origin prewarming in Standard mode vs strict zero-packet block in Private Browsing.
- Repackage and sign `build/Safarium.app` with the updated `BrowserCore` framework and `SafariShell` executable (`267 / 267` navigation, swipe, color-sampler, start-page, mock-engine, and tab-lifecycle tests passing with 0 regressions).
