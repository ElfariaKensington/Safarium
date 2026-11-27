# SafariX vs. Real macOS 27.3 Safari — 1:1 Ground-Truth Visual & Pixel Audit

**Measured live on macOS 27.3** from `/Applications/Safari.app` vs. `SafariX.app` at exact **`1200 × 800 pt` (`2400 × 1600 px` @2x Retina)** using `AXUIElement` dumps + `screencapture -l <wid>` (active key window, both with-shadow and `-o` no-shadow).

---

## 1. Reference & 1:1 Comparison Assets

### User-Dropped Screenshots (Cleanly Converted from 10-bit Display P3 HEIC → 8-bit sRGB PNG)
- `Reference/Screenshots/Pasted 2026-11-24 at 8.13.07 PM.png` (`3160×2110`) — Content Shield extension popover & crisp active light toolbar
- `Reference/Screenshots/Pasted 2026-11-24 at 8.13.13 PM.png` (`3160×2110`) — Bitwarden Vault extension popover
- `Reference/Screenshots/Pasted 2026-11-24 at 8.13.24 PM.png` (`3160×2120`) — Extension right-click context menu

### 1:1 Unscaled Retina Comparison Strips (Real Safari TOP/LEFT vs. SafariX BOTTOM/RIGHT)
- `Reference/Screenshots/comparisons/strip_01_single_light_clean.png` — Single-tab light (`google.com`), top 80pt @ 1:1
- `Reference/Screenshots/comparisons/strip_02_multi_light.png` — Multi-tab light (3 tabs: `google.com`, `Apple`, `MacBook Pro - Apple`), top 80pt @ 1:1
- `Reference/Screenshots/comparisons/strip_03_multi_dark.png` — Multi-tab dark (3 tabs, `apple.com/macbook-pro/` active), top 80pt @ 1:1
- `Reference/Screenshots/comparisons/strip_04_sidebar_clean.png` — Open Root Sidebar (`1 Tab`, `Google`, `iCloud Tabs`, `Saved`), side-by-side @ 1:1
- `Reference/Screenshots/comparisons/strip_05_corners_with_shadow.png` — All 4 window corners + traffic lights + trailing capsule @ 1:1 with native window shadow

### Raw Live AXUIElement Dumps (`1200 × 800 pt`)
- `Reference/Screenshots/audit_live/ax_real_01_single_light.txt`
- `Reference/Screenshots/audit_live/ax_real_02_multi_light.txt`
- `Reference/Screenshots/audit_live/ax_real_03_multi_dark.txt`
- `Reference/Screenshots/audit_live/ax_real_04_sidebar_root.txt` (Root tabs sidebar)
- `Reference/Screenshots/audit_live/ax_real_04_sidebar_open.txt` (Bookmarks sidebar sub-view)
- `Reference/Screenshots/audit_live/ax_safarix_02_multi_light.txt` & `ax_safarix_03_multi_dark.txt`

---

## 2. Exact Live `AXUIElement` Coordinate Comparison (`1200 × 800 pt` Window)

All coordinates are **relative to window top-left `(0, 0)` in macOS points**.

### A. Window Chrome, Corners & Traffic Lights
| Element | Real Safari (`1200×800`) | SafariX (`1200×800`) | Exact Delta / Root Cause |
|---|---|---|---|
| **Window Corner Radius** | `26.0 pt` (measured `25.6 pt` continuous squircle) | `26.0 pt` (concentricity broken by small pills!) | Real Safari's `19 pt` pill radius + `7 pt` inset = `26 pt` concentric! SafariX uses `15 pt` + `10 pt`. |
| **Toolbar / Titlebar Height** | **`52.0 pt`** (`AXToolbar: y = 0..52`) + crisp `0.5 pt` (1px) `#EAEAEA` bottom hairline at `y = 52.0` | **`46.0 pt`** (NO `NSToolbar`, NO bottom hairline!) | **-6.0 pt TOO SHORT** |
| **Traffic Light Rendering** | **Glossy 3D Tahoe Liquid Glass orbs** (`14 pt` visual diameter) | **Flat matte legacy circles** (`12 pt` visual diameter) | **NO `NSToolbar` attached!** AppKit only renders Tahoe 3D unified-toolbar traffic lights when `window.toolbar` (`toolbarStyle = .unified`) is attached! |
| **Close Button (`AXCloseButton`)** | `rel=(18.0, 18.0, 16.0, 16.0)` (center `y = 26`) | `rel=(19.0, 17.0, 12.0, 14.0)` (center `y = 24`) | `-4 pt W, -2 pt H`, wrong Y center (`-2 pt`) |
| **Minimize Button (`AXMinimizeButton`)** | `rel=(41.0, 18.0, 16.0, 16.0)` (**`23 pt` pitch**) | `rel=(39.0, 17.0, 12.0, 14.0)` (`20 pt` pitch) | **`-3 pt` spacing too tight!** |
| **FullScreen Button (`AXFullScreenButton`)** | `rel=(64.0, 18.0, 16.0, 16.0)` (**`23 pt` pitch**) | `rel=(59.0, 17.0, 12.0, 14.0)` (`20 pt` pitch) | **`-5 pt` X error!** |

### B. Toolbar Glass Capsules & Icon Scaling (THE #1 REASON TOOLBAR LOOKS "TINY & FLAT")
| Element | Real Safari (`1200×800`) | SafariX (`1200×800`) | Exact Delta |
|---|---|---|---|
| **All Toolbar Glass Capsules Height** | **`38.0 pt`** (`y = 7.0..45.0 pt`, `cornerRadius = 19.0 pt`) | **`30.0 pt`** (`y = 8.0..38.0 pt`, `cornerRadius = 15.0 pt`) | **`-8.0 pt` (-21% TOO SHORT!)** |
| **Left `[Sidebar \| Chevron]` Capsule** | `AXGroup (92, 0, 71, 52)`: `SidebarButton (95, 7, 38, 38)` + `TabGroupPicker (131, 7, 20, 38)` → visual capsule **`~64 × 38 pt`** at `x = 95, y = 7` | `54 × 30 pt` at `x = 84, y = 8` | **`-10 pt W, -8 pt H`, shifted 11 pt too far left!** |
| **Back Button `[ < ]`** (when visible) | `BackForwardSegmentedControl`: **`38 × 38 pt`** circle at `x = 166, y = 7` (expands to **`75 × 38 pt`** with Forward) | `30 × 30 pt` at `x = 146, y = 8` (expands to `58 × 30 pt`) | **`-8 pt W, -8 pt H` (-21% TOO SMALL!)** |
| **Right 4-Icon Unified Capsule** | `Downloads (1041, w=40)`, `Share (1081, w=36)`, `NewTab (1117, w=36)`, `TabOverview (1153, w=43)` → total **`155 × 38 pt`** (`y = 7..45`), **`4–6 pt` trailing margin** from right edge (`x = W - 159 .. W - 4`) | `126 × 30 pt` (`y = 8..38`), `10 pt` trailing margin | **`-29 pt W, -8 pt H`, wrong trailing margin!** |
| **Toolbar SF Symbol Size & Weight** | **Large, crisp `16.0–17.0 pt` (`.regular`/`.medium`), deep `#000000` (light) / `#FFFFFF` (dark)** | **Tiny, thin `12.5–13.5 pt`**, washed-out dark gray | **Icons are ~25% too small and too faint!** |

### C. Address Bar & Unified Multi-Tab Track (`1200 × 800 pt`)
| Element | Real Safari (`1200×800`) | SafariX (`1200×800`) | Exact Delta |
|---|---|---|---|
| **Address Bar / Tab Bar Height** | **`36.0 pt`** (`y = 8.0..44.0 pt`, `cornerRadius = 18.0 pt`) | **`29.0 pt`** (`y = 8.5..37.5 pt`, `cornerRadius = 14.5 pt`) | **`-7.0 pt` (-19.4% TOO THIN!)** |
| **Single-Tab Pill Width** | **`290.0 pt`** (`x = 455..745 pt` centered in `1200 pt` window; `280 pt` when sidebar open) | `300.0 pt × 29.0 pt` | Height `-7 pt` makes it look flat and stretched! |
| **Multi-Tab Container (3 tabs)** | `rel=(244.0, 8.0, 797.0, 36.0)` (without extensions: spans between left controls + `~8 pt` gap and right capsule `- 8 pt`) | `height = 29.0 pt` | `-7.0 pt` height |
| **Multi-Tab Width Distribution (3 tabs)** | **EQUAL 1/3 WIDTHS**: Tab 1 `265.0 pt`, Tab 2 `265.0 pt`, Tab 3 `265.0 pt` (`1 pt` gap between slots) | Active tab forced wider (~360pt) while inactive tabs squeezed narrower | Should distribute equal widths (with min-width clamp for active tab only when many tabs open) |
| **Favicon Size (Active & Inactive)** | **`20 × 20 pt`** AX (`16–18 pt` visual) at `y = 16..36` | `14 × 14 pt` | **`-4 to -6 pt` TOO SMALL** |
| **Tab / Domain Font Size** | **`13.5 pt`** regular/medium, **crisp primary `#1D1D1F` (light) / `#FFFFFF` (dark) ON BOTH ACTIVE AND INACTIVE TABS!** | `12.0–12.5 pt`, **inactive tabs washed-out gray (`secondaryInkColor`)**! | Inactive tab labels are far too dim in both light & dark mode! |
| **Inactive Tab Vertical Divider** | Crisp **`1 px × 18–20 pt`** hairline between adjacent inactive tabs | Barely visible thin/short divider | Make `1 px × 18 pt`, `rgba(0,0,0,0.16)` light / `rgba(255,255,255,0.18)` dark |
| **Trailing Icon in Active Pill** | `AssistantButton` (`line.3.horizontal` Page Menu, `23.5 × 34 pt`, reload on hover) | Always shows tiny `10.5 pt` `arrow.clockwise` | Slightly undersized (`10.5 pt` → `13–14 pt`) |

### D. Exact Pixel Color & HDR Brightness Audit (Real Safari vs. SafariX)
Sampled directly from `1200×800` active key-window captures:

| Surface | Real Safari (Measured sRGB) | SafariX (Measured sRGB) | Concrete Issue |
|---|---|---|---|
| **Light Toolbar Background** | `#FFFFFF` (`rgb(1.0, 1.0, 1.0)`) | `#FFFFFF` | OK, but missing `0.5 pt` bottom hairline `#EAEAEA` at `y = 52.0 pt` |
| **Light Multi-Tab Track (Inactive)** | **`#ECECEC`** (`rgb(0.928)`) | `#F1F1F1` (`rgb(0.947)`) | SafariX track is too pale; active white pill doesn't separate as cleanly |
| **Light Active Tab Interior** | **`#FEFDFE`** (`rgb(0.997)`) with soft subtle shadow | `#FFFFFF` | OK once `36 pt` height & native glass rim restored |
| **Dark Toolbar Background** | `#000000` (`rgb(0.000)`) | `#000000` | OK |
| **Dark Multi-Tab Track (Inactive)** | **`#212121`** (`rgb(0.130)`) | `#1E1E1E` (`rgb(0.119)`) | Close, slightly dark |
| **Dark Active Tab Interior** | **`#2A2A2A`** (`rgb(0.167)`) — ONLY **`+0.037`** lift over `#212121` track! | **`#373738`** (`rgb(0.218)`) — **+31% TOO BRIGHT / WASHED-OUT GRAY!** | `HDRColorFactory.activeTabTint` + `metalLayer` + `innerTopSpecularLayer` are stacking too much white alpha on dark mode! |
| **Dark Active Tab Top Rim** | **`#212121`..`#383838`** (subtle native glass edge) | **`#959495` (`rgb(0.585)`) HARSH GRAY-WHITE LINE!!** | `HDRPillHighlightView.swift:164` (`borderLayer` white `0.16` + `linearExposure` + `topSheen`) creates an ugly bright gray-white outline box around the active dark tab! |

### E. Open Sidebar (`strip_04_sidebar_clean.png` + `ax_real_04_sidebar_root.txt`)
| Element | Real Safari (`1200×800`) | SafariX (`1200×800`) | Exact Delta / Issue |
|---|---|---|---|
| **Sidebar Width & Divider** | **`240.0 pt`** (`AXSplitter` at `x = 239.5 pt`, **`0.5 pt` (1 Retina px)** `#929292` / `separatorColor`) | `272.0 pt` (`1.0 pt` divider) | **`+32 pt` TOO WIDE**, divider `2x` too thick |
| **Sidebar Appearance in Dark Webpages** | **FOLLOWS SYSTEM APPEARANCE (LIGHT)** even when webpage (`apple.com/macbook-pro`) is dark! | Turns flat charcoal dark `#242529` when webpage is dark! | Real Safari's sidebar NEVER turns dark just because a webpage has a dark background! Only follows macOS system appearance. |
| **Sidebar Surface Material** | Native vibrant bright `.sidebar` material (`NSVisualEffectView` without opaque fill override) | **Smothered by hardcoded opaque gray `layer.backgroundColor = rgb(0.945, 0.945, 0.950, 0.98)`** (`SafariSidebarView.swift:66, 164`) -> looks dull muddy gray `#E9E9E8`! | **DELETE hardcoded `visualEffectView.layer?.backgroundColor`!** Let native `NSVisualEffectView(.sidebar, blendingMode: .behindWindow)` (or `NSSplitViewController` sidebar item) render natively! |
| **Sidebar Header Capsule `[+ \| sidebar]`** | `AXGroup (159.5, 0, 76, 52)`: `NewTabGroupButton (158.5, 7, 38, 38)` + `SidebarButton (194.5, 7, 38, 38)` → **`76 × 38 pt`**, `y = 7..45`, `cornerRadius = 19 pt`, **`4.5 pt` from divider**, crisp white raised Liquid Glass, **large `16.5 pt` black icons** | Tiny `62 × 30 pt` at `y = 8..38`, `10 pt` from divider, flat gray fill, tiny `13 pt` thin icons | **`-14 pt W, -8 pt H, -3.5 pt icons`** |
| **`1 Tab` Selected Row** | `rel=(0, 52, 240, 32)`, pill inset `x = 10..230` (`220 × 32 pt`), `cornerRadius = 10 pt`, **`laptopcomputer` (`16 pt`)** vibrant `#007AFF` icon at `x = 19`, **BOLD `13.5 pt` `#000000` `"1 Tab"`** at `x = 49` | `30 pt` tall, wrong icon (`macwindow`, tiny `13.5 pt`), muted color | Wrong icon, undersized, dim |
| **Indented Tab Row (`Google`)** | `rel=(0, 84, 240, 32)` (**`32 pt` tall**), **`18 × 18 pt`** favicon at `x = 41, y = 91`, **`13.5 pt` `#000000`** label at `x = 65` | `27 pt` tall, `15 × 15 pt` favicon, `12.5 pt` text | `-5 pt` height, `-3 pt` icon |
| **`iCloud Tabs` & `Saved` Section Headers** | `y = 129` (`13 pt` gap after tabs) & `y = 193` (`13 pt` gap), **`12.0 pt` semibold** secondary label at `x = 17` | `11.0 pt`, `16 pt` gap | Slightly undersized |
| **`iPhone` / `Bookmarks` / `Reading List` / `Shared with You`** | Each **`32.0 pt` tall** (`y = 148, 212, 244, 276`), **large vibrant `#007AFF` `16.5 pt` SF Symbols** (`iphone`, `book`, `eyeglasses`, `shared.with.you`) at `x = 19`, **`13.5 pt` `#000000`** text at `x = 49` | `28 pt` tall, tiny `12.5–13.5 pt` thin icons | `-4 pt` height, `-3.5 pt` icon size |

---

## 3. Two Additional Live Runtime Bugs Caught During Testing

1. **Sidebar Open Animation / Glass Blob Collision (`strip_04_sidebar_toolbar.png`)**:
   - When toggling sidebar open, hiding `sidebarCapsule` inside `leftGlassContainer` (`NSGlassEffectContainerView`) while animating `leftGlassWidthConstraint` causes `sidebarCapsule` and `backForwardCapsule` to overlap and fuse into an ugly dark/gray peanut-shaped glass blob!
   - **Fix**: Put `sidebarCapsule` and `backForwardCapsule` in clean separate layout / hide `sidebarCapsule` immediately outside the merge zone (or use real `NSToolbar` items + `NSSplitViewController` with `.sidebar` item so AppKit handles sidebar titlebar/toolbar transitions natively!).
2. **Window Reopen / Blank Sidebar State**:
   - Closing tabs down to empty or reopening window after close left a black viewport and completely empty sidebar body (`strip_04_sidebar_panel.png`). Ensure `SafariSidebarView` always has non-zero content width constraints and `applicationShouldHandleReopen` ensures at least 1 active tab is attached to `webContentHost`.

---

## 4. Prioritized Actionable Fix List for `@shell-builder`

1. **Attach a Real Unified `NSToolbar` (`52.0 pt`) to `SafariWindow`** (`SafariWindowController.swift`):
   - Set `window.toolbar = NSToolbar(identifier: "SafariXToolbar")`, `window.toolbarStyle = .unified`, `toolbar.showsBaselineSeparator = false`, `window.isOpaque = true` (remove `isOpaque = false`!), and DELETE manual `positionTrafficLights()`!
   - This **immediately** gives SafariX native macOS 27 Tahoe **3D glossy `16×16 pt` traffic lights at `(18, 18), (41, 18), (64, 18)` (`23 pt` pitch)**, exact `52.0 pt` unified titlebar height, and native `26 pt` continuous window corner masking!
   - Add a crisp `0.5 pt` (1 Retina pixel) horizontal hairline at `y = 52.0 pt` (`NSColor.black.withAlphaComponent(0.08)` light / `NSColor.white.withAlphaComponent(0.08)` dark) between the `52 pt` toolbar and the webpage (matching Real Safari's `#EAEAEA` line at `y = 52.0`).

2. **Restore True macOS 27 `38 pt` Toolbar Glass Capsules & `16–17 pt` Bold/Crisp Icons** (`SafariMetrics.swift`, `GlassToolbarControls.swift`):
   - `toolbarHeight = 52.0`, `backgroundExtensionBleedHeight = 52.0`
   - `glassButtonSize = 38.0`, `glassButtonCornerRadius = 19.0`, `glassButtonTopInset = 7.0` (`19 + 7 = 26 pt`, 100% concentric with window corners!)
   - `leftGroup1StartX = 95.0`, `sidebarCapsuleWidth = 64.0`, `backButtonWidth = 38.0`, `backForwardCapsuleWidth = 75.0`, `leftGroupInterGap = 8.0`
   - `rightCapsuleWidth = 155.0` (button widths `38, 36, 36, 39` + `3 pt` padding), `rightGroupTrailingMargin = 6.0`
   - **Icon sizes**: Increase SF Symbols from `12.5–13.5 pt` → **`16.0–17.0 pt`** (`.regular` / `.medium` weight, `chevron.down` at `10.5 pt` `.semibold`) with **full primary ink contrast** (`NSColor.black.withAlphaComponent(0.88)` in light mode, `NSColor.white.withAlphaComponent(0.92)` in dark mode — NEVER washed-out gray!).
   - **Drop shadow / glass elevation**: Do NOT smother `NSGlassEffectView` with heavy custom `tintColor` alpha in light mode — keep `gv.tintColor = nil` (or ultra-subtle `0.02–0.05` alpha) on white light pages so `NSGlassEffectView(.regular, effectIsInteractive: true)` renders Real Safari's crisp raised white Liquid Glass with native specular rim & ambient drop shadow!

3. **Fix Address Bar & Multi-Tab Track (`36 pt` tall, Equal Widths, Clean Dark Mode!)** (`CompactTabAddressBar.swift`, `HDRHighlightLayer.swift`):
   - `tabPillHeight = 36.0`, `tabPillCornerRadius = 18.0`, `tabBarTopInset = 8.0` (`y = 8..44 pt`)
   - `activePillSingleTabWidth = 290.0` (`280.0` when sidebar open)
   - **Multi-tab equal widths**: Use equal width distribution (`stackView.distribution = .fillEqually` or equal-width constraints across active & inactive tabs when `tabs.count <= 4`, only clamping active tab min width `220 pt` at high tab counts), matching Real Safari's `265 / 265 / 265 pt`!
   - **Favicon & text**: Increase favicon to **`18 × 18 pt`** (or `20 × 20 pt` slot), font size to **`13.5 pt`** regular/medium, and use **CRISP PRIMARY INK** (`0.86–0.90` alpha black in light mode / `0.90` alpha white in dark mode) for **BOTH active AND inactive tab titles**!
   - **Light multi-tab track**: `#ECECEC` (`NSColor.black.withAlphaComponent(0.075)`), active tab pill crisp white raised glass (`#FEFEFE`), vertical hairline between adjacent inactive tabs `1 px × 18 pt` (`rgba(0,0,0,0.16)`).
   - **Dark multi-tab track & HDR FIX (CRITICAL!)**:
     - Track background: `#212121` (`NSColor.white.withAlphaComponent(0.13)` over black toolbar).
     - Active tab interior: **`#2A2A2A`** — subtle **`+0.037`** lift above the `#212121` track, NOT `#373738`!
     - **KILL THE HARSH `#959495` GRAY-WHITE TOP BORDER LINE** in `HDRPillHighlightView.swift`! Remove/reduce `borderLayer` on unfocused dark active tab to `NSColor.white.withAlphaComponent(0.08)` (`0.5 pt`) or let `NSGlassEffectView` draw its own native dark glass specular edge, set `innerTopSpecularLayer` alpha to `0.0` (or `<= 0.02`), and set `HDRColorFactory.activeTabTint` dark alpha to `0.10–0.14` (never `0.26`!).

4. **Rebuild Sidebar to 1:1 macOS 27 Native Look** (`SafariSidebarView.swift`, `SafariMetrics.swift`):
   - **Width**: **`240.0 pt`** (default), **`0.5 pt` (1px)** separator line (`NSColor.separatorColor`).
   - **Native vibrancy**: **REMOVE** `visualEffectView.layer?.backgroundColor = ...` completely! Let `NSVisualEffectView(material: .sidebar, blendingMode: .behindWindow, state: .active)` render macOS 27's bright native translucent sidebar!
   - **Follow System Appearance**: Do NOT turn the sidebar black when viewing a dark webpage (Real Safari keeps the sidebar in system light appearance!).
   - **Sidebar Header Capsule**: **`76 × 38 pt`** (`cornerRadius = 19 pt`, `y = 7..45`, `4.5 pt` from divider), crisp white `NSGlassEffectView` (`tintColor = nil`), **`16.5 pt`** crisp black icons (`plus.square.on.square` + `sidebar.left`).
   - **Rows**:
     - All rows **`32.0 pt`** tall!
     - `1 Tab` selected row: `y = 52..84`, `10 pt` horizontal inset, `cornerRadius = 10 pt`, **`laptopcomputer` (`16 pt`, `.medium`, `.systemBlue`)** + **`13.5 pt` `.semibold` `#000000`** label at `x = 49`.
     - Indented tab rows: `32 pt` tall, **`18 × 18 pt`** favicon at `x = 41`, **`13.5 pt` `#000000`** text at `x = 65`.
     - `iCloud Tabs` & `Saved` section headers: `13 pt` top gap, `12.0 pt` `.semibold` secondary label at `x = 17`.
     - `iPhone`, `Bookmarks`, `Reading List`, `Shared with You`: `32 pt` tall, **`16.5 pt` vibrant `.systemBlue`** SF Symbols (`iphone`, `book`, `eyeglasses`, `shared.with.you`) at `x = 19`, **`13.5 pt` `#000000`** text at `x = 49`.
