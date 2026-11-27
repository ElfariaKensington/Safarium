# macOS 27.3 Safari Layout & Visual Metrics

Measured directly from:
1. Running macOS 27.3 Safari (`CGWindowListCopyWindowInfo`, `AXUIElement` hierarchy dump, and window capture) on a 16x EDR MacBook Pro display.
2. Pixel-to-point measurements on `Reference/Screenshots/01_single_tab_google.png`, `02_sidebar_tabs.png`, `03_start_page_bookmarks.png`, `05_addressbar_popover_top.png`, and `06_addressbar_popover_reading_list.png`.

---

## 1. Window Geometry & Top Chrome
- **Window Corner Radius**: `30.0 pt` (measured 60 px @2x continuous curve inset). Native `NSWindow` with `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]` + `titlebarAppearsTransparent = true` + `titleVisibility = .hidden` gets this automatically on macOS 27.
- **Unified Toolbar / Titlebar Height**: `52 pt` (`AXToolbar` height = `52 pt` from `y = 0`).
- **Background Extension Bleed Height**: `52 pt` behind the top chrome (implemented via `NSBackgroundExtensionView` spanning the full window bounds so webpage content bleeds naturally behind the `52 pt` titlebar/toolbar and sidebar).

## 2. Traffic Lights (Window Controls)
Measured relative to window top-left `(0, 0)`:
- **Y Center**: `26 pt` (`y = 18..34 pt`, `16 × 16 pt` AX frame, `14 × 14 pt` visual circle).
- **Close (`AXCloseButton`)**: `x = 18 pt, y = 18 pt` (`center x = 26 pt`)
- **Minimize (`AXMinimizeButton`)**: `x = 41 pt, y = 18 pt` (`center x = 49 pt`)
- **Full Screen (`AXFullScreenButton`)**: `x = 64 pt, y = 18 pt` (`center x = 72 pt`)
- **Center-to-Center Spacing**: `23 pt` (`41 - 18 = 23`, `64 - 41 = 23`).
- **Clearance to First Glass Pill**: `14–15 pt` (`x = 80` to `95 pt`).

## 3. Exact Toolbar Glass Pills & Scaling (`01_single_tab_google.png`)
All toolbar pills sit vertically centered at `y = 7 pt` (`height = 38 pt`, `cornerRadius = 19 pt`, full capsule) inside `NSGlassEffectContainerView` with `NSGlassEffectView(effectIsInteractive = true)`.
- **Left `[sidebar.left | chevron.down]` Glass Pill**:
  - Width: `66 pt` (`x = 95.5..161.6 pt`), Height: `38 pt`, `cornerRadius = 19 pt`.
  - Icon size: `14–15 pt` SF Symbol (`sidebar.left` + `chevron.down`), `~12 pt` horizontal padding.
- **Circular `[ < ]` Back Button**:
  - Gap after Left Pill: **`6 pt`**.
  - Size: `38 × 38 pt` (`x = 167.5..206.4 pt`), `cornerRadius = 19 pt` (expands to `75 × 38 pt` capsule when Forward is visible).
  - Icon size: `14–15 pt` (`chevron.backward`).
- **Centered Single-Tab Address Bar Pill (`google.com`)**:
  - Width: **`280–285 pt`** (`x = 403.4..688.8 pt` in `1092 pt` window; `280 pt` in live AX dump).
  - Height: **`36 pt`** (`y = 8..44 pt`), `cornerRadius = 18 pt` (full capsule).
  - Inner layout: `16–20 pt` favicon + `13 pt` domain text centered, `23 × 34 pt` Page Menu (`line.3.horizontal` / `ellipsis`) at trailing edge.
- **Right Unified 4-Icon Capsule (`[Downloads, Share, New Tab, Tab Overview]`)**:
  - Width: **`152 pt`** (`x = 934.2..1086.3 pt` in `1092 pt` window; **`6 pt` trailing margin** from window right edge).
  - Height: **`38 pt`**, `cornerRadius = 19 pt`.
  - 4 equal `38 pt` icon slots (`4 × 38 = 152 pt`), `14–15 pt` SF Symbols (`arrow.down.circle`, `square.and.arrow.up`, `plus`, `square.on.square`).

## 4. Sidebar (`02_sidebar_tabs.png` & `03_start_page_bookmarks.png`)
- **Width**: **`322 pt`** in `02_sidebar_tabs.png` (approx. `280–322 pt` range; crisp `1 px` full-height vertical separator at `x = 322 pt`, `lum ≈ 0.77`).
- **Header (`y = 0..52 pt`)**:
  - Traffic lights stay at `(18, 18)`, `(41, 18)`, `(64, 18)` inside the top-left of the sidebar.
  - Top-right of sidebar header has a compact 2-icon Liquid Glass capsule `[plus.square.on.square | sidebar.left]` (`~68 × 38 pt`, `cornerRadius = 19 pt`, `y = 7 pt`, `~10 pt` from divider).
  - When sidebar is open, the sidebar toggle is **hidden** from the main pane toolbar so the main toolbar starts cleanly with `[ < ]` at `x = 330 pt` (`8 pt` past the `322 pt` divider).
- **Rows & Sections**:
  - **Selected `N Tabs` (`1 Tab`) Row**: `y = 53..85 pt` (**`32 pt` height**, `cornerRadius = 10 pt`, `10 pt` horizontal inset, `[macwindow] 1 Tab`).
  - **Indented Tab Rows**: `~28–30 pt` height, indented `~28 pt` from left (`16 × 16 pt` favicon + `13 pt` title).
  - **Section Headers (`iCloud Tabs`, `Saved`)**: `11 pt` semibold secondary label (`y ≈ 164 pt`, `y ≈ 229 pt`).
  - **`Saved` Rows (`Bookmarks`, `Reading List`, `Shared with You`)**: `~28–30 pt` height, blue SF Symbol icons (`book`, `eyeglasses`, `person.2`).

## 5. Active Tab HDR Brightness & Top-Edge Adaptive Tinting
- **HDR Brightness (Keep Subtle!)**:
  - Active tab pill should use a subtle, understated luminous lift — `NSColor(red:green:blue:alpha:linearExposure:)` with `linearExposure` around **`1.06–1.12`** (never blown-out bright grey-white), plus subtle `1px` inner rim highlight.
- **Top-Edge Adaptive Tinting (No `<meta name="theme-color">`)**:
  - Sample a `2–4 pt` horizontal strip from the top of the rendered page surface on load, scroll settle, and resize.
  - Smoothly animate `NSGlassEffectView.tintColor` toward the sampled top-edge color.
  - Compute WCAG relative luminance (`0.2126*R + 0.7152*G + 0.0722*B`) with hysteresis (`< 0.42` light-on-dark, `> 0.52` dark-on-light).

## 6. Focused Address Bar Popover (`05_addressbar_popover_top.png`, `06_addressbar_popover_reading_list.png`)
- **Popover Card**: Translucent Liquid Glass rounded card centered below the focused address bar (`~6 pt` vertical gap below the `36 pt` pill, width `~440–460 pt`, `cornerRadius ~22–24 pt`, soft ambient shadow).
- **Sections**: `Favorites` (6-column `~54 × 54 pt` icon tiles, `cornerRadius ~12 pt`), `Recently Viewed` (`~180 pt` cards + `5 Tabs >`), `Reading List` (`Show All >`, 2-column compact cards with `48 × 48 pt` thumbnail), `iCloud Tabs`.

## 7. Desktop 2 Window Placement
- Public `NSWindow.collectionBehavior` only supports `.moveToActiveSpace` / `.canJoinAllSpaces` (cannot target a specific Space ID).
- On this machine, `CGSCopyManagedDisplaySpaces` reports Space `1` (Desktop 1, active) and Space `2357` (Desktop 2).
- `SAFARIX_DESKTOP=2` can optionally move the window to Space `2357` via `SkyLight` (`CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSMoveWindowsToManagedSpace`).

## 8. Newly Dropped Reference Files (`/Users/elfaria/SafariX/`)
- `Pasted 2026-11-24 at 8.13.07 PM.heic` (`3160×2110`): Content Shield extension popover anchored under toolbar extension button.
- `Pasted 2026-11-24 at 8.13.13 PM.heic` (`3160×2110`): Bitwarden Vault extension popover anchored under toolbar extension button.
- `Pasted 2026-11-24 at 8.13.24 PM.heic` (`3160×2120`): Extension toolbar button right-click context menu (`Bitwarden >`, `Manage Extension...`, `Customize Toolbar...`).
