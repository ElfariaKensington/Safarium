# Safarium QA Report — 2026-11-26

Scope: all of `SafariShell/Sources/Safarium` (≈41k lines Swift) and `BrowserCore/src` (≈16k lines ObjC++), exercised four ways:
1. **Static audit** of every file by 15 read-only reviewers (12 by Luna, 3+1 re-run by Haiku after Luna's quota ran out); every finding quoted here that I did not reproduce at runtime was re-read against the code by me.
2. **Real Chromium engine** driven headlessly: an isolated copy of the app (own bundle id + `CFFIXED_USER_HOME`, so your running instance and profile were never touched) loaded local stress/probe pages; results came back through page beacons, `ps`, logs.
3. **In-process UI driving**: the real `SafariWindowController`/views run offscreen with `MockBrowserEngine` (never ordered on screen), stress-driven (300 tabs, resize extremes, toggle storms, hostile URLs) and rendered to PNG for layout review.
4. **Unit tests**: 1932 tests, 0 failures (`cd SafariShell && swift test`, ~2.5 min).

**Limits.** Computer-use access to the app was denied, so I did **not** drive the native chrome with clicks/typing or screenshot the live window; native chrome (toolbar, sidebar, drag/drop, trackpad gestures, animations at 120 Hz) was checked offscreen only. The H.264/VP9 and permission paths were checked through the real engine; Dock fly-animation, Touch ID/passkeys and extension popups were not exercised live. Luna hit its usage limit mid-run; remaining work fell back to Haiku, which also hit the limit (see "Not finished").

---

## 1. Highest-impact findings

| ID | Sev | Area | Finding | Status |
|---|---|---|---|---|
| P14-04 | **High (privacy)** | `SXExtensionManager.mm` | Every active-tab URL (and badge update) was appended to **`/tmp/sx_ext_bridge.log`, mode 0644** — 1,092 lines of your real browsing were in it, readable by any local process. | **Fixed** (logging removed, `BrowserCore` rebuilt, verified the patched dylib no longer writes); existing file `chmod 600`. Your running instance still uses the old dylib until you relaunch via `scripts/run.sh`. Consider deleting `/tmp/sx_ext_bridge.log`. |
| P11-01 | **High (remote crash)** | `NativeVideoOverlayView.formatTime` | `Int(sec)` traps for any finite page-controlled `duration` > 9.2e18 (e.g. 1e300) → whole browser process crashes. | **Fixed** (clamped) |
| P03-1 | High | `SafariWindowController` video command | videoID/cmd interpolated into JS after stripping only `'` → trailing `\` breaks out of the string (JS injection into main frame). | **Fixed** (`JSStringLiteral.make`) |
| P09-1 | High (security) | `ApplePasswordsPasskeyManager` | Saved passwords and passkey **private keys** stored as plain JSON (`safarium-vault.json`, 0600) — Touch ID gates UI only, not the file. | Open (design) — no vault file exists in your profile today |
| P14-01/02 | High | `SXExtensionManager.mm` | Manifest paths (`service_worker`, content-script `js`/`css`) not confined to the extension dir: a hostile extension can rewrite/delete files outside it or inject arbitrary local files into pages. | Open (native; patch in audit P14) |
| P14-03 | High | `SXExtensionManager.mm` | One global bridge token shared by all extensions gates `/active-tab`, `/snapshot` (writes PNG to `/tmp`), other extensions' events/badges. | Open |
| P13-01 | High | `SXBrowserClient.mm` | Permission prompt decides on the first category only and grants the whole bitmask (camera=Allow also grants location). | Open |
| P13-02 | High | `SXMediaTranscodeServer.mm` | ffmpeg output buffered in memory without cap/back-pressure. | Open |
| P12-1 | High | `SafariumEngineBridge.mm` | Closing a tab before CEF's async `CreateBrowser` completes leaves a live, hidden browser (late `handleBrowserCreated:` never closes it). | Open (needs native rebuild + manual repro) |
| P12-3 | Med (privacy) | `clearWebsiteData` | "Clear website data" removes cookies + caches but not Local Storage / IndexedDB and reports success. | Open |
| P15-01/02/03 | Med | `SXHelperMain.mm` | Password autofill pairs a login password with an unrelated form's username on any submit; scroll spams `autofill_blur` IPC forever; scrubbing a transcoded stream restarts ffmpeg on every pointermove. | Open |
| — | Med (design) | H.264 | Real engine has **no H.264/AAC** (`canPlayType` = ""). The fallback (system `ffmpeg` → VP8/Opus) only installs on `<video controls>`; `<video autoplay>`/custom-control players fail with `MEDIA_ERR_SRC_NOT_SUPPORTED`, and the feature depends on a Homebrew `ffmpeg` at fixed paths. Verified: with `controls` + ffmpeg present it plays; without `controls` it never engages. Widevine unsupported. | Open |

## 2. Bugs fixed in the source tree (all compile; regression-tested)

Backups: `.backup-QA/Sources.orig/`, `.backup-QA/BrowserCore-src.orig/`, `.backup-QA/Package.swift.orig`.

- **Controller leak on window close** (found by leak test): `windowWillClose` did not invalidate the sidebar `CADisplayLink`, which retains the controller. Fixed.
- **History titles were domains**: `didChangeURL` fires before the title arrives and nothing updated the history entry → History page showed `127.0.0.1`/domain for every visit (reproduced in the real engine). New `AssetLoader.updateHistoryTitle(url:title:)`, called from `didChangeTitle`.
- **Unpinning the first of several pinned tabs** left it in front of still-pinned tabs (P04-1).
- **Private-mode leaks**: favicons from private tabs were stored in the shared `FaviconCache` (P04-2); private Start Page showed persisted history as "Recently Viewed" (P07-01).
- **Drag & drop** accepted `javascript:`/`data:` URL objects (plain-text path was allow-listed) in the window and tab bar (P03-2, P05-1).
- **Unbounded growth**: closed-tab list (cap 50), `tabLastActiveAt`, Google-suggestion cache (cap 100).
- **BrowserSettings**: session active-index drifted when empty/malformed URLs were filtered; quick-search didn't percent-encode `& = + # ;` and only split on ASCII space (P01-1/2/8).
- **AssetLoader**: default-port stripping ignored scheme (`https://x:80` merged with `https://x`); `visitCount` overflow trap; history writes could land out of order (serial queue) (P01-3/4/5).
- **Extension converter** (P02-1/2/3): path traversal on HTML/script paths, unescaped quotes in generated `importScripts`/`import`, only first 6 scripts scanned for the `browser.` namespace.
- **Importer** (P02-4…7): bookmarks and reading list shared one dedupe set (lost entries), HREF entities not decoded (and `&amp;lt;` double-decoded), `https://` with no host accepted, unbounded folder recursion (now capped at 64). Netscape export now escapes `&` in HREF (P02-5).
- **Crashes**: `ExtensionsToolbarView.capsule(for:)` force-unwrap on merged zones (P09-5); `SecRandomCopyBytes` status ignored → all-zero passkey IDs (P09-4); `moveSelection` modulo-by-zero with no suggestions; `formatTime` (above).
- **Settings**: cancelling the stylesheet picker wiped the previous sheet (P08-1); duplicate profile names allowed (P08-2); stale host selection (P08-3).
- **UI correctness**: sidebar row didn't refresh when favicon was replaced (P05-4); recycled History row could show another site's icon (P07-02); `HTTP://…` typed in uppercase mis-classified in the address popover (P06-4); download overlay window could stay ordered in if the controller died mid-flight (P11-03).
- **Package.swift**: added `SafariumTests` target (links BrowserCore via `-I/-L`).
- **BrowserCore**: removed the `/tmp` URL logging (P14-04).

## 3. Open bugs (not changed — need a design decision, visual tuning, or native rebuild)

Layout/design
- **Auto Layout conflicts at every launch** (reproduced): `VerticalTabRailView.width == 0` vs its scroll view's leading/trailing insets, and `GlassToolbarClusterView.width == 0` vs `GlassActionCapsule.width == 36` (×several clusters). AppKit breaks a required constraint each time → log spam and an undefined layout. Fix: use priority < required on the inner width/insets, or drop the zero-width constraint and hide the view.
- **Min window width**: `SafariMetrics.minWindowWidth` is 680 but the window's Auto Layout fitting width is **834**, so `setContentSize` below 834 is clamped (headless Mock harness; re-check with the real engine).
- **Pinned tabs**: drop-slot hit-testing and the placeholder geometry assume equal slot widths and ignore the 36 pt pinned slots (P05-2); with many pinned tabs the slots exceed the track width (P05-3).
- **Long tab title in the sidebar** gave a row/`fittingSize` ≈ 1033 pt in a 240 pt sidebar (no truncation constraint); verify in the live app.
- Fresh profiles show hard-coded "Apple"/"GitHub" in Recently Viewed (P07-03); wallpaper deleted on disk → white tile titles on light background (P07-04).
- Animations ignore **Reduce Motion** everywhere (download fly, hover/press, customize sheet) (P08-5, P11-05). `LiquidGlassCircleButton.animateScale` offset (P11-02) not verified (depends on layer anchor).

Behavior / perf
- **PERF-1**: every tab open/close rebuilds the whole tab strip and re-renders the HDR sheen: 25 ms/tab at 1 tab → 58 ms/tab at 300 (300 open+close = 23 s). Profile: `refreshToolbarUI → CompactTabAddressBar.update/rebuildAndLayout` (56 %) and `HDRPillHighlightView.accentTintColor.didSet → renderMetalEDRSheen` re-rendered even when the colour is unchanged. Documented as `XCTExpectFailure` in `UIStressDriveTests`.
- ElasticScrollEngine forwards the whole wheel event instead of the remainder when an unwind crosses zero (P10-1); PullToRefresh decodes 40 PNGs per view init on the main thread (P10-3); Settings Websites pane reads manifests synchronously (P08-4).
- `ChromiumBrowserEngine`: Back is disabled after `safarium://start` (P01-6); sync extension APIs return `true` before completing (P01-7).
- Passkeys: registrable domain = last two labels (no Public Suffix List) (P09-2); assertions always sign `crossOrigin:false` (P09-3).
- `normalizedURLKey` still lower-cases the path (kept; documented by tests); scheme comparisons throughout are case-sensitive (low).
- Mock engine only: `preset(for:)` matches any URL containing `hn` as Hacker News.

## 4. Runtime results (real Chromium 156 engine)

- Stability: 15 odd-URL launches (download 60 MB, redirect loop, refused, DNS fail, HTTP 500, 2000-paragraph DOM, `file://`, `javascript:`, `view-source:`, `chrome://gpu`, `data:`, 100 KB URL, `safarium://history|start`, canvas) — **no crash, no hang**. 60 MB download completed byte-exact.
- Performance: heavy page (6000 animated nodes + 60 Hz programmatic scroll): renderer 198 % CPU (page cost), **browser process 0.7 %**. 5-minute soak: browser RSS flat at 119–162 MB (no native leak). Idle 0.7 % CPU / 80 MB.
- Feature probe: WebGL2 (ANGLE/Metal M1 Pro), WebGPU, WebAuthn (platform authenticator reported unavailable in the ad-hoc copy), Service Workers, storage/cookies persist, VP9/AV1/Opus/MP3 play. Permission/dialog requests block until a native sheet is answered (handlers exist). User-Agent is Chrome 156 on "Mac OS X 10_15_7", not Safari.
- 0 Swift compiler warnings on a clean build.
- Test-pollution note: before the suite was sandboxed, two exploratory runs added `https://gemini.google.com` (Mock default page) to your real `browsing-history.json`; I removed that entry (94 entries now; backup kept in the session scratchpad). My first launch of the isolated copy also cleared `Default/Service Worker/{ScriptCache,Database}` in your real profile (the app does that on every start; caches only).

## 5. Test suite

`cd SafariShell && swift test` → **1932 tests, 0 failures** (also runnable per class). Every class inherits `HermeticTestCase`, which redirects the home directory to a throw-away sandbox; `SandboxGuardTests` fails if any class bypasses it. No network, no real Chromium, no on-screen windows.

| Area | Test files |
|---|---|
| Settings, engine models, URL input, Mock engine, metrics | `BrowserSettingsTests`, `BrowserEngineModelsTests`, `URLInputNormalizerTests`, `MockBrowserEngineTests`, `SafariMetricsTests` |
| Persistence, favicons, JS literals | `AssetLoaderTests`, `AssetLoaderHistoryTests`, `FaviconCacheTests`, `FaviconPixelAnalysisTests`, `JSStringLiteralTests` (round-trips through JavaScriptCore) |
| Import / extension conversion | `BrowserDataImporterTests` (96.5 % lines), `ExtensionCompatibilityConverterTests` (99.8 %), `ImportAndClearHistoryTests` |
| Tabs, sidebar, overview, hover | `CompactTabAddressBarTests`, `SafariSidebarViewTests`, `TabOverviewViewTests`, `TabHoverPreviewTests` |
| Popover, start page, history, error page | `AddressBarPopoverTests`, `StartPageViewTests`, `HistoryPageViewTests`, `PageLoadErrorViewTests` |
| Settings, toolbar, popovers | `SettingsWindowTests`, `CustomizeToolbarTests`, `ExtensionsToolbarTests`, `GlassToolbarControlsTests`, `PopoverControllersTests` |
| Scroll/animation/media/passkeys | `ElasticScrollEngineTests`, `PullToRefreshTests`, `TopEdgeColorSamplerTests`, `HDRAndBackdropTests`, `DownloadAnimationTests`, `NativeVideoOverlayTests`, `PasskeyManagerTests`, `SwipeNavigationTests` |
| Window controller | `Window*Tests`, `DesktopSpacePlacerTests`, `UIStressDriveTests` (300-tab stress, resize extremes, toggle storms, leak checks), `VisualSnapshotTests` (offscreen PNGs → `scratchpad/shots`) |

Known open bugs are pinned with `XCTExpectFailure("BUG …")` so the suite stays green and flips red when fixed. To write the visual snapshots somewhere else, edit `outDir` in `VisualSnapshotTests`/`UIStressDriveTests` (it points at the session scratchpad).

Some tests rely on small visibility changes (`private` → internal) and a few behavior-preserving helper extractions made by the test writers (e.g. `AddressBarPopoverController.nextSelectionIndex`, which also removed a modulo-by-zero).

## 6. Not finished

- Test-writing agents for the tab/popover/settings/scroll/window areas (T4–T8) and T3 stopped on the usage limit; what they had written is integrated and passing, but their own gap lists/REPORT.md were not produced. Likely thin spots: `SafariWindowController` internals (6k lines; only lifecycle/drag-drop/privacy/layout invariants), `SwipeNavigationController`, `SafariTabDragCoordinator` morph geometry, `AppDelegate`, `ChromiumBrowserEngine`, all ObjC++ (BrowserCore has no unit tests; only the manual `BrowserCoreSmokeTest`).
- Not applied (need your call or a native rebuild/manual repro): the open items above, notably P14-01/02/03, P13-01/02, P12-1/3, P15-01/02/03, vault encryption (use Keychain), the AutoLayout conflicts and the 834 pt minimum width.
- Not verified live: native chrome visuals/animations on screen, trackpad gestures, Dock fly animation, extension popups, Touch ID/passkeys.

Audit reports (per-file findings with quoted code and suggested patches) are in the session scratchpad: `…/scratchpad/audit/P01.md … P15.md`.

## 7. Live window check (added after "test drive it too")

Computer-use only grants this app **read-only** (screenshots; it is classed as a browser), so I could not click or type in the live window. What I did instead: relaunched the isolated copy (fixed build) on different URLs and screenshotted the real window each time.

- Page with a red fixed header: toolbar/address capsule tint to match the page (top-edge colour sampler works); fixed header + scrollbar render correctly.
- DNS-failure URL: "Safarium Can't Open the Page" error view, address field shows the failed host.
- `confirm()` from a page: native sheet ("From \"127.0.0.1\": confirm test", Cancel/OK) over a dimmed page.
- `safarium://history`: **history titles are now real page titles** ("Probe", "Heavy & \"quoted\" 'title' …") — confirms the history-title fix end to end (before it showed `127.0.0.1`).
- Start Page renders Favorites grid + Recently Viewed; traffic lights dim correctly when the window is inactive.

Still unverified on screen: tab strip with many tabs, sidebar/overview animations, drag & drop, trackpad gestures, Dock fly animation, dark appearance (needs input access, which this app's tier doesn't allow).

## 8. Live test drive with your mcu tool (real window, real Chromium, isolated copy)

Driven by window ID on the isolated copy only (never your running instance): address bar typing, Return, Cmd+T/L/1/F/Shift+L/Shift+\, screenshots after each step. Notes on the tool: background clicks/typing did not reach the address field until a `hid:true` click (which also dragged the window ~357 pt — a tool artifact); keyboard hotkeys worked in the background, and once Cmd+T/Cmd+L focused a field, `type` worked.

Found and fixed:
- **Typing `localhost`, `localhost:3000` or `127.0.0.1:8765/x` ran a Google search / opened `https://…` and failed** ("can't establish a secure connection"). `URLInputNormalizer` now defaults localhost, `*.localhost`, `*.local`, IPv4 and `[IPv6]` input to `http://` (tests updated, +1 detection test). Verified live: `127.0.0.1:8765/heavy.html` and `localhost:8765/vid3.html` load.

Found and **now fixed** (see §9):
- **The window silently widens as you use it** (new, high-visibility layout bug): width 1200 → 1272 once 3 tabs were open → 1356 with the sidebar open → **1392 after closing the sidebar** (left edge fixed, so it grows to the right; it never shrinks back). Cause is Auto Layout min-size from the toolbar/tab track (see §3 "Min window width" — the effective minimum is far above `SafariMetrics.minWindowWidth` = 680 and the default 1200 is already too small once tabs exist). In Safari the tab strip compresses and the sidebar narrows the content instead.
- Find bar: typing "Fixed" showed only "Fixe" highlighted (last character appears un-highlighted until the next update) — minor, re-check manually.

Verified working live: multi-tab strip with truncated titles and emoji/quote/backslash title; tab overview with live thumbnails (video tab shows the transcoded video + HUD, canvas tab shows its frame); sidebar (tabs list, Bookmarks/Reading List); Cmd+1 tab switch; find bar; address-bar popover with Google suggestions; toolbar tint follows page colour; Recently Viewed cards for `127.0.0.1` and `localhost`.

## 9. Window-widening fix

Root cause (two parts, both in `CompactTabAddressBar`):
1. The tab-track width constraint (`trackWidthConstraint`, priority 760) and its centring constraint (740) sat **above** `NSLayoutPriority.windowSizeStayPut` (500), so whenever the sidebar took 240 pt the toolbar "needed" more room and AppKit grew the window (and never shrank it back). They are now 499/498.
2. That constraint had been silently masking a second bug: the bar's manually laid-out slots/active pill are sized from the *constant*, and `layout()` is skipped while an animation hold is active (the sidebar slide holds it until after the final constraint update), so after the sidebar opened the pill stayed sized for the old width and overflowed ~80 pt into the right-hand capsule. The bar now invalidates its layout when its width changes (`setFrameSize`), re-reads the available width in `layout()`, and catches up when the animation hold is released (`endFocusRingDeferral`).

Verified: new `WindowGrowthTests` (window width unchanged across 8 tabs and a sidebar open/close; tab strip never extends past its bar or into the right capsule with the address field focused) — both fail before the fix. Live (mcu, isolated copy): 4 tabs + sidebar open + sidebar closed keeps the window at 1200 pt with no overlap. Full suite: 1936 tests, 0 failures.

Caveat: if the window is dragged narrower than the toolbar can hold, the track now shrinks to what is left instead of the window being forced wider; the separate "declared min width 680 vs real minimum" item (§3) is unchanged.

## 10. Resolution pass (all open items from §1–§3)

Suite: **1945 tests, 0 failures**. Native code rebuilt (`ninja -C BrowserCore/build`) and verified in the isolated copy (live page probes + mcu drive). Backups of every original: `.backup-QA/`. **Relaunch with `scripts/run.sh` to embed the new BrowserCore dylib/helpers** (your running instance still has the old ones).

### Fixed in this pass
| Item | Fix |
|---|---|
| P14-01/02 extension path escape | `SXContainedPath` confines `service_worker`, legacy entry and content-script `js`/`css` paths to the extension directory |
| P14-03 shared bridge token | per-extension key + `HMAC-SHA256(globalToken, key)` token; `/active-tab` and `/snapshot` need `tabs`/`activeTab`/`<all_urls>` in the manifest; caller-chosen `/tmp` screenshot path removed; `/events`, `/badge`, `/menus` reject an `extId` the registry knows under a different directory (fail-open for not-yet-registered ids) |
| P13-01 permission prompt | every requested category is evaluated; unknown bits fall through to the native prompt |
| P13-02 transcode buffer | 16 MiB cap with back-pressure on ffmpeg's pipe |
| P12-1 create/close race | late-created browser is closed; close notification is de-duplicated |
| P12-2 stale snapshot | generation advanced in `loadURL`; stale completions always dropped |
| P12-3 clear website data | marks Local/Session Storage, IndexedDB, File System, WebSQL, service workers for deletion **before the next launch** (Chromium holds them open while running) — in-session pages keep their storage until restart |
| P15-01/02/03 helper JS | autofill needs a password input in the submitted form; blur clears `activeAuthInput`; scrubbing an unknown-duration transcode commits on release |
| P09-1 vault | AES-256-GCM, key in Keychain (this-device-only) with a 0600 key-file fallback; legacy plaintext vaults migrate on first read |
| P09-2/3 passkeys | embedded public-suffix subset (`co.uk`, `github.io`, …), no suffix matching for public suffixes, trailing-dot/IP hosts; client data carries real `crossOrigin`/`topOrigin`; CBOR 32-bit lengths |
| H.264 | fallback now also covers `<video>` **without** `controls` (verified live: error 4 → plays) |
| Auto Layout conflicts | rail and capsule width constraints no longer fight required insets (remaining benign log: AppKit's internal `NSStackView.Empty.Width.Min` ≥ 6 pt on empty extension capsules) |
| Min window width | Start Page side margins demoted below the drag-resize priority; `windowWillResize` enforces 680×460 |
| Pinned tabs | one shared slot-width model for layout, drop hit-testing and placeholder; pinned slots shrink instead of overflowing |
| Reduce Motion | customize sheet, download fly + bounce, video button hover/press |
| P01-6 | Back from `safarium://start` returns to the page it was opened over |
| P01-7 | fire-and-forget extension APIs return false for obviously invalid input (missing path/manifest/id) |
| PERF-1 | pooled tab separators + skipped redundant HDR sheen: 300 open+close 23 s → ~10 s (rest is Mock demo-page building); regression guard in `UIStressDriveTests` |
| P10-1 | only the residual delta is forwarded to the page after an overscroll unwind (point/fixed/line deltas scaled together) |
| P10-3, P08-4 | spinner frames decoded once per process; extension manifest metadata cached by mtime |
| 30+ smaller bugs found by the new tests | URL input (case-insensitive schemes, ftp://, `+` in searches, display host case), path-case-sensitive history keys, history title/uppercase-scheme/empty-title, hex colours, favicon luma, pinned unpin order, saved active index, reorder with duplicate ids, transferred-tab selection, sidebar signature collisions/staleness, popover keys (port/query), index modulo, monogram fallback, private-window suggestions/recents, numeric HTML entities, converter scan limit and `..` id, zoom 250/300 %, `MacCtrl` glyph, Mock private flag |

### Decisions / not changed (stating them plainly)
- **Start Page "Privacy Report"**: not a bug but a never-built feature (no tracker statistics exist, and the Edit popover has no toggle). Test now records that decision.
- **Not bugs after checking**: sidebar long titles truncate correctly in the live app; find-bar "Fixe" was capture timing; `LiquidGlassCircleButton` hover offset left alone (depends on the layer anchor, visual tuning).
- **ffmpeg** is still an external dependency of the H.264 fallback (Homebrew paths); it cannot be bundled here. DRM (Widevine) remains unsupported.
- **Not verified**: real extension installs under the new bridge credentials (none installed in the isolated copy — please try Bitwarden/Content Shield after relaunching; if anything breaks, restore `.backup-QA/BrowserCore-src.orig/SXExtensionManager.mm` and rebuild); trackpad momentum with the residual-scroll forward; Keychain prompts for the vault key on a signed build.
- **Coverage**: the unit tests still do not cover "everything" — `SafariWindowController` internals, `SwipeNavigationController`, drag-coordinator morph geometry and all ObjC++ have no direct tests (native fixes were verified live, not by unit tests).
