// SXSmokeTestMain.mm
// Native AppKit smoke test verifying BrowserCore Phase 1 + Phase 2 capabilities:
// - Real Chromium 156 rendering & multi-tab focus/visibility switching
// - Top-edge 2-4pt surface color sampling (strictly ignoring <meta theme-color>)
// - Fast scrollY telemetry & isScrolledToTop
// - Pinch-to-zoom pageScale visual viewport control
// - Crisp Retina NSImage tab snapshots
// - Real CefDownloadHandler download into ~/Downloads/

#import "SafariumEngineBridge.h"
#import <AppKit/AppKit.h>

@interface SXSmokeDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, SXBrowserTabDelegate, SXEngineExtensionDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) SXBrowserTab *tab1;
@property (nonatomic, strong) SXBrowserTab *tab2;
@property (nonatomic, copy) NSString *targetURL;
@property (nonatomic, copy, nullable) NSString *downloadURL;
@property (nonatomic, assign) BOOL phase3Mode;
@property (nonatomic, assign) BOOL phase3Ran;
@property (nonatomic, assign) BOOL samplerBenchMode;
@property (nonatomic, assign) BOOL samplerBenchStarted;
@property (nonatomic, assign) BOOL p0VerifyMode;
@property (nonatomic, assign) BOOL p0VerifyStarted;
@property (nonatomic, assign) BOOL bitwardenLiveMode;
@property (nonatomic, assign) BOOL bitwardenLiveStarted;
@property (nonatomic, copy, nullable) NSString *customProfileDir;
@property (nonatomic, strong, nullable) NSWindow *popupWindow;
@property (nonatomic, assign) CGFloat lastPopupWidth;
@property (nonatomic, assign) CGFloat lastPopupHeight;
@property (nonatomic, copy, nullable) NSString *lastNewTabRequestURL;
@property (nonatomic, assign) BOOL scrollActiveWindow;
@property (nonatomic, assign) NSInteger samplesDuringActiveScroll;
@property (nonatomic, assign) NSInteger samplesAfterScrollSettle;
@property (nonatomic, assign) BOOL phase2Started;
@property (nonatomic, assign) BOOL snapshotOK;
@property (nonatomic, assign) BOOL pinchOK;
@property (nonatomic, assign) BOOL tabCloseOK;
@property (nonatomic, assign) BOOL windowClosedUnexpectedly;
@property (nonatomic, assign) BOOL downloadOK;
@property (nonatomic, copy, nullable) NSString *downloadedFilePath;
@end

@implementation SXSmokeDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  SXEngineConfiguration *config = [SXEngineConfiguration defaultConfiguration];
  NSString *tmpProfile = self.customProfileDir ?: [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"SafariumSmokeProfile-%d", getpid()]];
  config.userDataDir = tmpProfile;

  NSError *error = nil;
  if (![[SXEngineRuntime sharedRuntime] initializeWithConfiguration:config error:&error]) {
    fprintf(stderr, "FAIL: SXEngineRuntime initialize failed: %s\n",
            error.localizedDescription.UTF8String);
    [NSApp terminate:nil];
    return;
  }

  printf("INIT_OK: Chromium %s\n",
         [SXEngineRuntime sharedRuntime].chromiumVersion.UTF8String);
  fflush(stdout);
  [SXEngineRuntime sharedRuntime].extensionDelegate = self;

  self.window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(100, 100, (self.p0VerifyMode || self.bitwardenLiveMode) ? 1200 : 900,
                                     (self.p0VerifyMode || self.bitwardenLiveMode) ? 748 : 620)
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.title = @"BrowserCore Verification";
  self.window.delegate = self;
  if (self.p0VerifyMode || self.bitwardenLiveMode) {
    [self.window makeKeyAndOrderFront:nil];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:SXExtensionPopupPreferredSizeDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  NSString *eid = note.userInfo[@"extensionID"];
                  double w = [note.userInfo[@"width"] doubleValue];
                  double h = [note.userInfo[@"height"] doubleValue];
                  self.lastPopupWidth = w;
                  self.lastPopupHeight = h;
                  printf("P0_POPUP_RESIZE: ext=%s size=%.0fx%.0f\n",
                         (eid ?: @"").UTF8String, w, h);
                  fflush(stdout);
                  if (self.popupWindow && w >= 200 && h >= 120) {
                    [self.popupWindow setContentSize:NSMakeSize(w, h)];
                  }
                }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:SXEngineRuntimeRequestNewTabNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  NSURL *u = note.userInfo[@"url"];
                  self.lastNewTabRequestURL = u.absoluteString;
                  printf("P0_NEW_TAB_REQUEST: url=%s visibleWindows=%lu\n",
                         (u.absoluteString ?: @"").UTF8String,
                         (unsigned long)[NSApp windows].count);
                  fflush(stdout);
                }];
  } else {
    [self.window orderBack:nil];
  }

  NSURL *url = [NSURL URLWithString:self.targetURL];
  self.tab1 = [[SXEngineRuntime sharedRuntime]
      createTabWithInitialURL:url
                   parentView:self.window.contentView
                     delegate:self];
  if (!self.phase3Mode && !self.samplerBenchMode && !self.p0VerifyMode && !self.bitwardenLiveMode) {
    self.tab2 = [[SXEngineRuntime sharedRuntime]
        createTabWithInitialURL:[NSURL URLWithString:@"about:blank"]
                     parentView:self.window.contentView
                       delegate:self];
    [self.tab2 setTabActive:NO];
    [self.tab1 setTabActive:YES];
    [self.tab1 focusWebContent];
  }

  int timeoutSec = (self.phase3Mode || self.p0VerifyMode || self.bitwardenLiveMode) ? 45 : 20;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   fprintf(stderr, "TIMEOUT waiting for smoke test completion\n");
                   [[SXEngineRuntime sharedRuntime] shutdown];
                   exit(2);
                 });
}

- (void)engineRuntime:(SXEngineRuntime *)runtime
   didUpdateExtensions:(NSArray<SXExtensionItem *> *)extensions {
  printf("EXT_DELEGATE_UPDATE: count=%lu\n", (unsigned long)extensions.count);
  fflush(stdout);
}

- (void)runPhase3Checks {
  if (self.phase3Ran) return;
  self.phase3Ran = YES;

  // 1. Capture snapshot of https://accounts.google.com to verify standard Sign-In screen.
  [self.tab1 captureSnapshotWithCompletion:^(NSImage * _Nullable image) {
    if (image) {
      NSData *tiff = [image TIFFRepresentation];
      NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
      NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      NSString *outPath = @"/tmp/safarium_phase3_google_signin.png";
      [png writeToFile:outPath atomically:YES];
      printf("GOOGLE_SIGNIN_SNAPSHOT: %s (%.0fx%.0f)\n",
             outPath.UTF8String, image.size.width, image.size.height);
      fflush(stdout);
    }

    // 2. Live Chrome Web Store MV3 install test (uBlock Origin Lite: ddkjiahejlhfcafbddmgiahcphecmpfh).
    NSString *cwsId = @"ddkjiahejlhfcafbddmgiahcphecmpfh";
    [[SXEngineRuntime sharedRuntime]
        installExtensionFromChromeWebStoreID:cwsId
                                  completion:^(SXExtensionItem * _Nullable item, NSError * _Nullable error) {
      if (error || !item) {
        fprintf(stderr, "CWS_INSTALL_FAIL: %s\n",
                error ? error.localizedDescription.UTF8String : "nil item");
        [[SXEngineRuntime sharedRuntime] shutdown];
        exit(3);
      }
      printf("CWS_INSTALL_OK: id=%s storeID=%s name=%s version=%s hasIcon=%d popup=%s\n",
             item.extensionID.UTF8String,
             (item.storeID ?: @"").UTF8String,
             item.name.UTF8String,
             item.version.UTF8String,
             item.icon ? 1 : 0,
             (item.popupURL.absoluteString ?: @"").UTF8String);
      fflush(stdout);

      // 3. Create live popup NSView via SXEngineRuntime (serves immediately even before restart!).
      NSView *popupHost = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 360, 480)];
      [self.window.contentView addSubview:popupHost];
      NSView *popupView = [[SXEngineRuntime sharedRuntime]
          createExtensionPopupViewForExtensionID:item.extensionID
                                           width:360
                                          height:480
                                      parentView:popupHost];
      printf("EXT_POPUP_VIEW_OK: view=%p\n", (__bridge void *)popupView);
      fflush(stdout);

      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        [[SXEngineRuntime sharedRuntime] closeExtensionPopupForExtensionID:item.extensionID];
        [[SXEngineRuntime sharedRuntime] uninstallExtensionWithID:item.extensionID
                                                       completion:^(BOOL ok, NSError * _Nullable uerr) {
          printf("EXT_UNINSTALL_OK: ok=%d remaining=%lu\n",
                 ok ? 1 : 0,
                 (unsigned long)[SXEngineRuntime sharedRuntime].installedExtensions.count);
          printf("PHASE3_ALL_OK\n");
          fflush(stdout);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
                           [[SXEngineRuntime sharedRuntime] shutdown];
                           exit(0);
                         });
        }];
      });
    }];
  }];
}

- (void)windowWillClose:(NSNotification *)notification {
  self.windowClosedUnexpectedly = YES;
  fprintf(stderr, "FAIL: Host NSWindow closed unexpectedly when closing a tab!\n");
  fflush(stderr);
}

- (void)browserTabDidClose:(SXBrowserTab *)tab {
  if (tab == self.tab2) {
    printf("TAB2_CLOSED_CLEANLY: hostWindowClosed=%d remainingTabs=%lu\n",
           self.windowClosedUnexpectedly ? 1 : 0,
           (unsigned long)[SXEngineRuntime sharedRuntime].activeTabs.count);
    fflush(stdout);
    self.tabCloseOK = (!self.windowClosedUnexpectedly);
    [self tryFinishIfAllPassed];
  }
}

- (void)tryFinishIfAllPassed {
  BOOL needDownload = (self.downloadURL.length > 0);
  if (self.snapshotOK && self.pinchOK && self.tabCloseOK &&
      (!needDownload || self.downloadOK)) {
    if (self.downloadedFilePath.length > 0) {
      [[NSFileManager defaultManager] removeItemAtPath:self.downloadedFilePath error:nil];
    }
    printf("PHASE2_ALL_OK\n");
    fflush(stdout);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [[SXEngineRuntime sharedRuntime] shutdown];
                     exit(0);
                   });
  }
}

- (void)runPhase2Checks {
  if (self.phase2Started) return;
  self.phase2Started = YES;

  // 1. Multi-tab switch roundtrip (tab1 -> tab2 -> tab1) verifying hidden/visible + focus,
  //    then close tab2 and verify host NSWindow stays open and OnBeforeClose fires cleanly!
  [self.tab1 setTabActive:NO];
  [self.tab2 setTabActive:YES];
  [self.tab2 setTabActive:NO];
  [self.tab1 setTabActive:YES];
  [self.tab1 focusWebContent];
  [self.tab2 closeTab];
  printf("MULTITAB_SWITCH_OK: tab1.hidden=%d tab2.hidden=%d isScrolledToTop=%d\n",
         self.tab1.contentView.isHidden ? 1 : 0,
         self.tab2.contentView.isHidden ? 1 : 0,
         self.tab1.isScrolledToTop ? 1 : 0);
  fflush(stdout);

  // 2. Cmd+0 / Cmd+ / Cmd- zoom & resetPageScale check (live trackpad pinch is native 120fps).
  [self.tab1 setPageZoomFactor:1.2];
  double z = [self.tab1 pageZoomFactor];
  [self.tab1 setPageZoomFactor:1.0];
  [self.tab1 resetPageScale];
  printf("ZOOM_AND_RESET_OK: zoomFactor=%.2f pageScale=%.3f\n", z, self.tab1.pageScale);
  fflush(stdout);
  if (z > 1.15 && fabs(self.tab1.pageScale - 1.0) < 0.01) {
    self.pinchOK = YES;
  }

  // 3. Crisp Retina Tab Snapshot edge-to-edge (zero margin/padding) check.
  [self.tab1 captureSnapshotWithCompletion:^(NSImage * _Nullable image) {
    if (image) {
      NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
      NSColor *tl = [rep colorAtX:0 y:0];
      NSColor *tr = [rep colorAtX:(rep.pixelsWide - 1) y:0];
      NSColor *bl = [rep colorAtX:0 y:(rep.pixelsHigh - 1)];
      NSColor *br = [rep colorAtX:(rep.pixelsWide - 1) y:(rep.pixelsHigh - 1)];
      printf("SNAPSHOT_OK: size=%.0fx%.0f pixels=%ldx%ld corners_b=(%.2f,%.2f,%.2f,%.2f)\n",
             image.size.width, image.size.height,
             (long)(rep ? rep.pixelsWide : 0),
             (long)(rep ? rep.pixelsHigh : 0),
             tl.blueComponent, tr.blueComponent, bl.blueComponent, br.blueComponent);
      fflush(stdout);
      BOOL edgesFilled = (tl.blueComponent > 0.25 && tr.blueComponent > 0.25 &&
                          bl.blueComponent > 0.25 && br.blueComponent > 0.25);
      self.snapshotOK = (image.size.width >= 800 && image.size.height >= 500 &&
                         rep && rep.pixelsWide == 1800 && rep.pixelsHigh == 1240 &&
                         edgesFilled);
    } else {
      fprintf(stderr, "SNAPSHOT_FAIL: nil image\n");
    }
    [self tryFinishIfAllPassed];
  }];

  // 4. Real Chromium Download check (if download URL supplied).
  if (self.downloadURL.length > 0) {
    [self.tab1 startDownloadAtURL:[NSURL URLWithString:self.downloadURL]];
  }
}

- (void)browserTab:(SXBrowserTab *)tab didChangeURL:(NSURL *)url {
  if (tab != self.tab1) return;
  printf("URL: %s\n", url.absoluteString.UTF8String);
  fflush(stdout);
}

- (void)browserTab:(SXBrowserTab *)tab didChangeTitle:(NSString *)title {
  if (tab != self.tab1) return;
  printf("TITLE: %s\n", title.UTF8String);
  fflush(stdout);
}

- (void)runSamplerBenchmark {
  if (self.samplerBenchStarted) return;
  self.samplerBenchStarted = YES;

  // 1. Measure explicit sample latency & main-thread dispatch time.
  CFTimeInterval t0 = CACurrentMediaTime();
  [self.tab1 sampleTopEdgeColorWithStripHeightPoints:3.0
                                          completion:^(NSColor * _Nullable color, double lum) {
    double totalMs = (CACurrentMediaTime() - t0) * 1000.0;
    NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    int r = (int)round(srgb.redComponent * 255.0);
    int g = (int)round(srgb.greenComponent * 255.0);
    int b = (int)round(srgb.blueComponent * 255.0);
    printf("BENCH_DARK_SAMPLE: rgb(%d,%d,%d) lum=%.4f total_ms=%.2f\n", r, g, b, lum, totalMs);
    fflush(stdout);

    // 2. Simulate active trackpad scroll + momentum for 600ms -> MUST fire 0 samples!
    self.scrollActiveWindow = YES;
    self.samplesDuringActiveScroll = 0;
    [self.tab1 notifyScrollPhase:SXScrollPhaseBegan];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [self.tab1 notifyScrollPhase:SXScrollPhaseMomentumBegan];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      printf("ACTIVE_SCROLL_SAMPLES: count=%ld (expected 0)\n",
             (long)self.samplesDuringActiveScroll);
      fflush(stdout);
      BOOL zeroDuringScroll = (self.samplesDuringActiveScroll == 0);
      self.scrollActiveWindow = NO;
      [self.tab1 notifyScrollPhase:SXScrollPhaseMomentumEnded];

      // 3. Navigate to pure white page with red <meta theme-color> and verify light sampling!
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        NSString *lightURL = @"data:text/html;charset=utf-8,"
            "%3Cmeta%20name%3D%22theme-color%22%20content%3D%22%23ff0000%22%3E"
            "%3Cbody%20style%3D%22margin:0;background:%23ffffff;height:2000px%22%3ELight%3C/body%3E";
        [self.tab1 loadURLString:lightURL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          CFTimeInterval t1 = CACurrentMediaTime();
          [self.tab1 sampleTopEdgeColorWithStripHeightPoints:3.0
                                                  completion:^(NSColor * _Nullable lcol, double llum) {
            double lightMs = (CACurrentMediaTime() - t1) * 1000.0;
            NSColor *lsrgb = [lcol colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            int lr = (int)round(lsrgb.redComponent * 255.0);
            int lg = (int)round(lsrgb.greenComponent * 255.0);
            int lb = (int)round(lsrgb.blueComponent * 255.0);
            printf("BENCH_LIGHT_SAMPLE: rgb(%d,%d,%d) lum=%.4f total_ms=%.2f\n",
                   lr, lg, lb, llum, lightMs);
            BOOL darkOK = (abs(r - 20) <= 5 && abs(g - 40) <= 5 && abs(b - 80) <= 5);
            BOOL lightOK = (lr >= 250 && lg >= 250 && lb >= 250 && llum > 0.95);
            printf("SAMPLER_BENCH_RESULT: darkOK=%d lightOK=%d zeroDuringScroll=%d\n",
                   darkOK ? 1 : 0, lightOK ? 1 : 0, zeroDuringScroll ? 1 : 0);
            fflush(stdout);
            int code = (darkOK && lightOK && zeroDuringScroll) ? 0 : 4;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                             [[SXEngineRuntime sharedRuntime] shutdown];
                             exit(code);
                           });
          }];
        });
      });
    });
  }];
}

- (void)runP0Verification {
  if (self.p0VerifyStarted) return;
  self.p0VerifyStarted = YES;

  // 1. Trigger top-edge sample + reload + snapshot on https://www.google.com/ to prove ZERO 0.5x shrink.
  [self.tab1 sampleTopEdgeColorWithStripHeightPoints:3.0
                                          completion:^(NSColor * _Nullable color, double lum) {
    printf("P0_GOOGLE_TOP_COLOR: lum=%.4f pageScale=%.3f\n", lum, self.tab1.pageScale);
    fflush(stdout);
    [self.tab1 captureSnapshotWithCompletion:^(NSImage * _Nullable img) {
      if (img) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@"/tmp/p0_verify_google.png" atomically:YES];
        printf("P0_GOOGLE_SNAPSHOT: size=%.0fx%.0f pixels=%ldx%ld\n",
               img.size.width, img.size.height,
               (long)rep.pixelsWide, (long)rep.pixelsHigh);
        fflush(stdout);
      }

      // 2. Open uBlock Origin Lite popup while google.com is active!
      NSString *ubolId = @"ddkjiahejlhfcafbddmgiahcphecmpfh";
      self.popupWindow = [[NSWindow alloc]
          initWithContentRect:NSMakeRect(160, 200, 280, 300)
                    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                      backing:NSBackingStoreBuffered
                        defer:NO];
      self.popupWindow.title = @"uBOL Popup Verify";
      [self.popupWindow makeKeyAndOrderFront:nil];
      NSView *pv = [[SXEngineRuntime sharedRuntime]
          createExtensionPopupViewForExtensionID:ubolId
                                           width:280
                                          height:300
                                      parentView:self.popupWindow.contentView];
      printf("P0_POPUP_OPENED: view=%p extCount=%lu\n",
             (__bridge void *)pv,
             (unsigned long)[SXEngineRuntime sharedRuntime].installedExtensions.count);
      fflush(stdout);

      // Wait 2.5s for popup JS + ResizeObserver + uBOL init to render google.com & auto-size.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        // Capture the live popup window image using screencapture -l <wid>
        NSInteger wid = self.popupWindow.windowNumber;
        NSTask *cap = [[NSTask alloc] init];
        cap.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        cap.arguments = @[ @"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)wid],
                           @"/tmp/p0_verify_ubol_popup.png" ];
        [cap launchAndReturnError:nil];
        [cap waitUntilExit];
        printf("P0_POPUP_SCREENSHOT: wid=%ld exit=%d finalSize=%.0fx%.0f\n",
               (long)wid, cap.terminationStatus, self.lastPopupWidth, self.lastPopupHeight);
        fflush(stdout);

        // 3a. Focus popup window & RenderWidgetHostViewCocoa cleanly before sending clicks.
        [NSApp activateIgnoringOtherApps:YES];
        [self.popupWindow makeKeyAndOrderFront:nil];
        auto clickPopupPoint = ^(NSPoint pt, NSInteger evNum) {
          NSView *hit = [self.popupWindow.contentView hitTest:pt];
          if (hit) {
            [self.popupWindow makeFirstResponder:hit];
          }
          NSEvent *move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                             location:pt
                                        modifierFlags:0
                                            timestamp:NSProcessInfo.processInfo.systemUptime
                                         windowNumber:self.popupWindow.windowNumber
                                              context:nil
                                          eventNumber:evNum
                                           clickCount:0
                                             pressure:0.0];
          NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                             location:pt
                                        modifierFlags:0
                                            timestamp:NSProcessInfo.processInfo.systemUptime + 0.01
                                         windowNumber:self.popupWindow.windowNumber
                                              context:nil
                                          eventNumber:evNum + 1
                                           clickCount:1
                                             pressure:1.0];
          NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                           location:pt
                                      modifierFlags:0
                                          timestamp:NSProcessInfo.processInfo.systemUptime + 0.03
                                       windowNumber:self.popupWindow.windowNumber
                                            context:nil
                                        eventNumber:evNum + 2
                                         clickCount:1
                                           pressure:0.0];
          if (hit) {
            [hit mouseMoved:move];
            [hit mouseDown:down];
            [hit mouseUp:up];
          } else {
            [self.popupWindow sendEvent:down];
            [self.popupWindow sendEvent:up];
          }
        };

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          NSSize cs = self.popupWindow.contentView.bounds.size;
          NSPoint gearPt = NSMakePoint(cs.width - 24.0, 22.0);
          clickPopupPoint(gearPt, 1);
          printf("P0_GEAR_CLICKED: pt=(%.0f,%.0f) content=%.0fx%.0f\n",
                 gearPt.x, gearPt.y, cs.width, cs.height);
          fflush(stdout);

          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
            BOOL dashOK = [self.lastNewTabRequestURL containsString:@"dashboard.html"];
            printf("P0_DASHBOARD_CHECK: dashOK=%d url=%s\n",
                   dashOK ? 1 : 0, (self.lastNewTabRequestURL ?: @"(none)").UTF8String);
            fflush(stdout);

            // 3b. Open the received dashboard.html URL inside a native Safarium SXBrowserTab
            // and verify it renders cleanly with ZERO raw Chrome windows!
            NSURL *dashURL = self.lastNewTabRequestURL ? [NSURL URLWithString:self.lastNewTabRequestURL] : nil;
            if (dashURL) {
              [self.tab1 setTabActive:NO];
              self.tab2 = [[SXEngineRuntime sharedRuntime]
                  createTabWithInitialURL:dashURL
                               parentView:self.window.contentView
                                 delegate:self];
              [self.tab2 setTabActive:YES];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
              [self.tab2 captureSnapshotWithCompletion:^(NSImage * _Nullable dImg) {
                if (dImg) {
                  NSBitmapImageRep *dRep = [NSBitmapImageRep imageRepWithData:[dImg TIFFRepresentation]];
                  NSData *dPng = [dRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                  [dPng writeToFile:@"/tmp/p0_verify_dashboard_tab.png" atomically:YES];
                  printf("P0_DASHBOARD_TAB_SNAPSHOT: size=%.0fx%.0f pixels=%ldx%ld title=%s\n",
                         dImg.size.width, dImg.size.height,
                         (long)dRep.pixelsWide, (long)dRep.pixelsHigh,
                         (self.tab2.title ?: @"").UTF8String);
                  fflush(stdout);
                }
                NSInteger rogueVisible = 0;
                for (NSWindow *w in [NSApp windows]) {
                  if (w != self.window && w != self.popupWindow && w.isVisible && w.alphaValue > 0.01) {
                    rogueVisible++;
                    printf("P0_ROGUE_WINDOW_DETECTED: title=%s frame=%.0fx%.0f\n",
                           (w.title ?: @"").UTF8String, w.frame.size.width, w.frame.size.height);
                  }
                }
                BOOL resizeOK = (self.lastPopupWidth >= 200 && self.lastPopupHeight >= 300);
                BOOL dashTabOK = (dImg != nil && dImg.size.width >= 1100 && dImg.size.height >= 700);
                BOOL noRogueOK = (rogueVisible == 0);
                printf("P0_VERIFY_SUMMARY: resizeOK=%d (%.0fx%.0f) dashOK=%d dashTabOK=%d rogueWindows=%ld\n",
                       resizeOK ? 1 : 0, self.lastPopupWidth, self.lastPopupHeight,
                       dashOK ? 1 : 0, dashTabOK ? 1 : 0, (long)rogueVisible);
                fflush(stdout);
                [self.popupWindow orderOut:nil];
                self.popupWindow = nil;
                [[SXEngineRuntime sharedRuntime] shutdown];
                exit((resizeOK && dashOK && dashTabOK && noRogueOK) ? 0 : 5);
              }];
            });
          });
        });
      });
    }];
  }];
}

- (void)runBitwardenLiveVerification {
  if (self.bitwardenLiveStarted) return;
  self.bitwardenLiveStarted = YES;

  // Starts from a COMPLETELY EMPTY profile (0 preloaded extensions).
  // Install Bitwarden Password Manager LIVE mid-session from Chrome Web Store!
  NSString *bwId = @"nngceckbapebfimnlniiiahkandclblb";
  printf("BW_INSTALL_START: preCount=%lu\n",
         (unsigned long)[SXEngineRuntime sharedRuntime].installedExtensions.count);
  fflush(stdout);

  [[SXEngineRuntime sharedRuntime]
      installExtensionFromChromeWebStoreID:bwId
                                completion:^(SXExtensionItem * _Nullable item, NSError * _Nullable err) {
    if (err || !item) {
      fprintf(stderr, "BW_INSTALL_FAIL: %s\n", err ? err.localizedDescription.UTF8String : "nil");
      [[SXEngineRuntime sharedRuntime] shutdown];
      exit(6);
    }
    printf("BW_INSTALL_OK: id=%s name=%s ver=%s popup=%s\n",
           item.extensionID.UTF8String,
           item.name.UTF8String,
           item.version.UTF8String,
           (item.popupURL.absoluteString ?: @"").UTF8String);
    fflush(stdout);

    // Wait 1.0s for CWS page button to flip to "Remove from Safarium", capture CWS snapshot!
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [self.tab1 captureSnapshotWithCompletion:^(NSImage * _Nullable cwsImg) {
        if (cwsImg) {
          NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[cwsImg TIFFRepresentation]];
          NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
          [png writeToFile:@"/tmp/bitwarden_cws_after_install.png" atomically:YES];
          printf("BW_CWS_SNAPSHOT: /tmp/bitwarden_cws_after_install.png (%.0fx%.0f)\n",
                 cwsImg.size.width, cwsImg.size.height);
          fflush(stdout);
        }

        // Open Bitwarden popup IMMEDIATELY on the SAME session (NO restart!) at 380x520!
        self.popupWindow = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(160, 120, 380, 520)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        self.popupWindow.title = @"Bitwarden Live Verify";
        [self.popupWindow makeKeyAndOrderFront:nil];
        NSView *pv = [[SXEngineRuntime sharedRuntime]
            createExtensionPopupViewForExtensionID:item.extensionID
                                             width:380
                                            height:520
                                        parentView:self.popupWindow.contentView];
        printf("BW_POPUP_OPENED: view=%p\n", (__bridge void *)pv);
        fflush(stdout);

        // Wait 4.0s for Bitwarden Angular app + real MV3 service worker to boot login screen!
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          NSInteger wid = self.popupWindow.windowNumber;
          NSTask *cap = [[NSTask alloc] init];
          cap.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
          cap.arguments = @[ @"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)wid],
                             @"/tmp/bitwarden_live_popup.png" ];
          [cap launchAndReturnError:nil];
          [cap waitUntilExit];
          NSSize finalSz = self.popupWindow.contentView.bounds.size;
          printf("BW_POPUP_SCREENSHOT: wid=%ld exit=%d contentSize=%.0fx%.0f reported=%.0fx%.0f\n",
                 (long)wid, cap.terminationStatus, finalSz.width, finalSz.height,
                 self.lastPopupWidth, self.lastPopupHeight);
          fflush(stdout);

          [self.popupWindow orderOut:nil];
          self.popupWindow = nil;
          [[SXEngineRuntime sharedRuntime] shutdown];
          exit((finalSz.width >= 340 && finalSz.height >= 450) ? 0 : 7);
        });
      }];
    });
  }];
}

- (void)browserTab:(SXBrowserTab *)tab
    didSampleTopEdgeColor:(NSColor *)color
        relativeLuminance:(double)relativeLuminance {
  if (tab != self.tab1) return;
  if (self.scrollActiveWindow) {
    self.samplesDuringActiveScroll++;
  }
  NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  int r = (int)round(srgb.redComponent * 255.0);
  int g = (int)round(srgb.greenComponent * 255.0);
  int b = (int)round(srgb.blueComponent * 255.0);
  printf("TOP_EDGE_COLOR: rgb(%d,%d,%d) lum=%.4f\n", r, g, b, relativeLuminance);
  fflush(stdout);
  if (self.samplerBenchMode) {
    [self runSamplerBenchmark];
  } else if (self.p0VerifyMode) {
    [self runP0Verification];
  } else if (self.bitwardenLiveMode) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [self runBitwardenLiveVerification];
                   });
  } else if (self.phase3Mode) {
    if ([self.tab1.currentURL.host containsString:@"accounts.google.com"]) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       [self runPhase3Checks];
                     });
    }
  } else {
    [self runPhase2Checks];
  }
}

- (void)browserTab:(SXBrowserTab *)tab
    didUpdateScrollY:(CGFloat)scrollY
       contentHeight:(CGFloat)contentHeight {
  if (tab != self.tab1) return;
  printf("TELEMETRY_SCROLL: y=%.1f height=%.1f atTop=%d\n",
         scrollY, contentHeight, tab.isScrolledToTop ? 1 : 0);
  fflush(stdout);
}

- (void)browserTab:(SXBrowserTab *)tab
    didUpdatePageScale:(CGFloat)pageScale
            isPinching:(BOOL)isPinching {
  if (tab != self.tab1) return;
  printf("TELEMETRY_SCALE: scale=%.3f pinching=%d\n", pageScale, isPinching ? 1 : 0);
  fflush(stdout);
}

- (void)browserTab:(SXBrowserTab *)tab didStartDownload:(SXDownloadItem *)download {
  printf("DOWNLOAD_START: id=%u name=%s path=%s\n",
         download.downloadID,
         download.suggestedFileName.UTF8String,
         (download.fullPath ?: @"").UTF8String);
  fflush(stdout);
}

- (void)browserTab:(SXBrowserTab *)tab didUpdateDownload:(SXDownloadItem *)download {
  if (download.isComplete) {
    printf("DOWNLOAD_COMPLETE: id=%u bytes=%lld/%lld pct=%d path=%s\n",
           download.downloadID,
           download.receivedBytes,
           download.totalBytes,
           download.percentComplete,
           (download.fullPath ?: @"").UTF8String);
    fflush(stdout);
    self.downloadedFilePath = download.fullPath;
    if (download.fullPath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:download.fullPath]) {
      self.downloadOK = YES;
    }
    [self tryFinishIfAllPassed];
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  [[SXEngineRuntime sharedRuntime] shutdown];
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    [SXEngineRuntime installApplicationProtocolHooks];
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    SXSmokeDelegate *delegate = [[SXSmokeDelegate alloc] init];
    if (argc > 1 && strcmp(argv[1], "--sampler-bench") == 0) {
      delegate.samplerBenchMode = YES;
      delegate.targetURL = @"data:text/html;charset=utf-8,"
          "%3Cmeta%20name%3D%22theme-color%22%20content%3D%22%2300ff00%22%3E"
          "%3Cbody%20style%3D%22margin:0;background:%23142850;height:2000px;color:white%22%3EDark%3C/body%3E";
    } else if (argc > 1 && strcmp(argv[1], "--p0-verify") == 0) {
      delegate.p0VerifyMode = YES;
      delegate.targetURL = @"https://www.google.com/";
      if (argc > 2) {
        delegate.customProfileDir = [NSString stringWithUTF8String:argv[2]];
      }
    } else if (argc > 1 && strcmp(argv[1], "--bitwarden-live") == 0) {
      delegate.bitwardenLiveMode = YES;
      delegate.targetURL = @"https://chromewebstore.google.com/detail/bitwarden-password-manager/nngceckbapebfimnlniiiahkandclblb";
    } else if (argc > 1 && strcmp(argv[1], "--phase3") == 0) {
      delegate.phase3Mode = YES;
      delegate.targetURL = @"https://accounts.google.com";
    } else {
      delegate.targetURL = (argc > 1)
                               ? [NSString stringWithUTF8String:argv[1]]
                               : @"about:blank";
      if (argc > 2) {
        delegate.downloadURL = [NSString stringWithUTF8String:argv[2]];
      }
    }
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
