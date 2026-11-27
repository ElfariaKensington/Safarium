# SafariX Existing Asset Catalog

Catalog of all pre-extracted assets in `Reference/`:

## 1. Symbols (`Reference/Components/symbols/`)
- **Total Files**: `321` (`80` unique symbols × 4 formats: `.svg`, `.png` @1x, `@2x.png`, `@3x.png`, plus directory metadata).
- **Sample Dimensions**: `a.magnify` is `23×19` (@1x), `46×38` (@2x), `69×57` (@3x).
- **Key Toolbar & Chrome Symbols Available**:
  - Navigation: `chevron.left`, `chevron.right`, `chevron.backward`, `chevron.forward`, `arrow.clockwise`, `arrow.counterclockwise`, `xmark`
  - Sidebar & Tabs: `sidebar.leading`, `sidebar.left`, `plus`, `square.on.square`, `rectangle.stack`, `plus.square.on.square`, `pin.fill`, `pin.slash`
  - Actions & Menus: `square.and.arrow.up`, `arrow.down.circle`, `arrow.down.circle.fill`, `ellipsis.circle`, `slider.horizontal.3`, `gearshape`, `gearshape.fill`
  - Security & Status: `lock.fill`, `lock.open.fill`, `shield.fill`, `shield.lefthalf.filled`, `magnifyingglass`, `safari`, `globe`, `sparkles`
  - Extensions & Media: `puzzlepiece.extension`, `puzzlepiece.extension.fill`, `speaker.wave.2.fill`, `speaker.slash.fill`, `play.fill`, `pause.fill`, `stop.fill`

## 2. Wallpapers (`Reference/Components/wallpapers/`)
- **Count**: `9` full-res wallpapers + `9` thumbnails (`thumbnails/`, `1024×1024`) + `manifest.json` (`safariVersion: "27.3"`, `defaultWallpaperId: "safari-27-blue"`).
- **Full-Res Dimensions**:
  - `safari-27-blue.jpg`, `safari-27-orange.jpg`, `safari-27-pink.jpg`: `6016 × 6016`
  - `california-dogface-butterfly.png`, `california-grizzly-bear.jpg`, `california-quail.jpg`, `emoji-fast-food.jpg`, `emoji-safari-animals.jpg`, `emoji-vacation.jpg`: `6000 × 6000`

## 3. Pull-to-Refresh Spinner (`Reference/Animations/spinner/`)
- **Total Files**: `40` PNGs (`44 × 44 px` @2x = `22 × 22 pt`).
- **Pull Phase (24 frames)**: `pull-01@2x.png` .. `pull-24@2x.png` (drive `0..23` from overscroll progress `0.0..1.0`).
- **Spin Phase (16 frames)**: `spin-00@2x.png` .. `spin-15@2x.png` (loop at ~30–60 fps while loading/refreshing).

## 4. Video Reference Frames (`Reference/Animations/video-frames/`)
- **`safari_anim2/`** (Address bar / tab focus & unfocus animation reference):
  - `frame_001.jpg` .. `frame_156.jpg`: `156` frames, `960 × 192 px` (top-chrome crop) + `sheet_03.jpg`..`sheet_06.jpg`.
  - `focus/strip.png`: `882 × 2816 px` (focus animation contact strip).
  - `unfocus/strip.png`: `882 × 2288 px` (unfocus animation contact strip).
- **`safari_pinch_frames/`** (Pinch-to-tab-overview animation reference):
  - `frame_001.jpg` .. `frame_115.jpg`: `115` frames, `960 × 918 px` + `sheet_01.jpg`..`sheet_03.jpg`.
