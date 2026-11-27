// SXTopEdgeColorSampler.mm
// Clean, zero-jank pixel-based top-edge color sampler for Safarium BrowserCore.

#import "SXTopEdgeColorSampler.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <vector>

#pragma mark - Pure Off-Main-Thread Pixel Decoding & Trimmed-Mean Color Math

double SXRelativeLuminanceSRGB(double r, double g, double b) {
  auto linearize = [](double c) -> double {
    if (c <= 0.0) return 0.0;
    if (c >= 1.0) return 1.0;
    return (c <= 0.03928) ? (c / 12.92) : std::pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
}

static NSColor * _Nullable SXTrimmedMeanStripColorAtOffset(NSData *imageData,
                                                            size_t topOffsetPixels,
                                                            size_t topStripPixels,
                                                            double * _Nullable outLuminance,
                                                            double * _Nullable outUniformity,
                                                            double * _Nullable outEdgeDelta);

NSColor * _Nullable SXTrimmedMeanTopStripColorFromImageData(NSData *imageData,
                                                            size_t topStripPixels,
                                                            double * _Nullable outLuminance) {
  return SXTrimmedMeanStripColorAtOffset(imageData, 0, topStripPixels, outLuminance, nullptr, nullptr);
}

static NSColor * _Nullable SXTrimmedMeanStripColorAtOffset(NSData *imageData,
                                                            size_t topOffsetPixels,
                                                            size_t topStripPixels,
                                                            double * _Nullable outLuminance,
                                                            double * _Nullable outUniformity,
                                                            double * _Nullable outEdgeDelta) {
  if (!imageData || imageData.length == 0) {
    return nil;
  }

  CGImageSourceRef source =
      CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
  if (!source) {
    return nil;
  }
  CGImageRef fullImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (!fullImage) {
    return nil;
  }

  size_t fullW = CGImageGetWidth(fullImage);
  size_t fullH = CGImageGetHeight(fullImage);
  if (fullW == 0 || fullH == 0) {
    CGImageRelease(fullImage);
    return nil;
  }

  // Crop strictly the top 2-4pt strip (in device pixels) without touching Chromium viewport scale.
  // The page runs behind Safarium's toolbar, so the colour that meets the toolbar is the strip just below it.
  size_t offset = topOffsetPixels < fullH ? topOffsetPixels : 0;
  size_t cropH = std::max<size_t>(1, std::min<size_t>(topStripPixels, fullH - offset));
  CGImageRef stripImage =
      CGImageCreateWithImageInRect(fullImage, CGRectMake(0, offset, fullW, cropH));
  CGImageRelease(fullImage);
  if (!stripImage) {
    return nil;
  }

  size_t srcW = CGImageGetWidth(stripImage);
  size_t srcH = CGImageGetHeight(stripImage);
  if (srcW == 0 || srcH == 0) {
    CGImageRelease(stripImage);
    return nil;
  }

  // Clamp decode target to a tiny row buffer (at most 160x4 px) for < 0.2ms decode.
  size_t sampleW = std::min<size_t>(srcW, 160);
  size_t sampleH = std::min<size_t>(srcH, 4);
  size_t bytesPerRow = sampleW * 4;
  std::vector<uint8_t> pixels(bytesPerRow * sampleH, 0);

  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      pixels.data(), sampleW, sampleH, 8, bytesPerRow, srgb,
      (uint32_t)kCGImageAlphaPremultipliedLast | (uint32_t)kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(srgb);

  if (!ctx) {
    CGImageRelease(stripImage);
    return nil;
  }

  CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
  CGContextDrawImage(ctx, CGRectMake(0, 0, sampleW, sampleH), stripImage);
  CGContextRelease(ctx);
  CGImageRelease(stripImage);

  struct PixelSample {
    double r;
    double g;
    double b;
    double luma;
  };
  std::vector<PixelSample> samples;
  samples.reserve(sampleW * sampleH);

  for (size_t i = 0; i < sampleW * sampleH; ++i) {
    const uint8_t *p = &pixels[i * 4];
    double a = p[3] / 255.0;
    if (a < 0.08) {
      continue;
    }
    double r = std::min(1.0, (p[0] / 255.0) / a);
    double g = std::min(1.0, (p[1] / 255.0) / a);
    double b = std::min(1.0, (p[2] / 255.0) / a);
    double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    samples.push_back(PixelSample{r, g, b, luma});
  }

  if (samples.empty()) {
    return nil;
  }

  // Sort by perceived luminance and take trimmed mean (drop extreme 10% outliers on each end)
  // so small corner logos or scrollbars never skew the top-edge adaptive glass tint.
  std::sort(samples.begin(), samples.end(),
            [](const PixelSample &a, const PixelSample &b) {
              return a.luma < b.luma;
            });

  size_t trim = samples.size() >= 10 ? (samples.size() / 10) : 0;
  size_t beginIdx = trim;
  size_t endIdx = samples.size() - trim;
  if (endIdx <= beginIdx) {
    beginIdx = 0;
    endIdx = samples.size();
  }

  double sumR = 0.0, sumG = 0.0, sumB = 0.0;
  size_t count = endIdx - beginIdx;
  for (size_t i = beginIdx; i < endIdx; ++i) {
    sumR += samples[i].r;
    sumG += samples[i].g;
    sumB += samples[i].b;
  }

  double avgR = sumR / (double)count;
  double avgG = sumG / (double)count;
  double avgB = sumB / (double)count;

  if (outUniformity || outEdgeDelta) {
    size_t validCols = 0;
    size_t matchingCols = 0;
    double segR[3] = {0, 0, 0}, segG[3] = {0, 0, 0}, segB[3] = {0, 0, 0};
    size_t segN[3] = {0, 0, 0};
    const double tol = 22.0 / 255.0;
    for (size_t x = 0; x < sampleW; ++x) {
      double cr = 0, cg = 0, cb = 0;
      size_t cn = 0;
      for (size_t y = 0; y < sampleH; ++y) {
        const uint8_t *p = &pixels[(y * sampleW + x) * 4];
        double a = p[3] / 255.0;
        if (a < 0.08) continue;
        cr += std::min(1.0, (p[0] / 255.0) / a);
        cg += std::min(1.0, (p[1] / 255.0) / a);
        cb += std::min(1.0, (p[2] / 255.0) / a);
        cn++;
      }
      if (cn == 0) continue;
      cr /= (double)cn; cg /= (double)cn; cb /= (double)cn;
      validCols++;
      double d = std::max({std::fabs(cr - avgR), std::fabs(cg - avgG), std::fabs(cb - avgB)});
      if (d <= tol) matchingCols++;
      size_t seg = (x * 4 < sampleW) ? 0 : ((x * 4 >= sampleW * 3) ? 2 : 1);
      segR[seg] += cr; segG[seg] += cg; segB[seg] += cb; segN[seg]++;
    }
    if (outUniformity) {
      *outUniformity = validCols > 0 ? ((double)matchingCols / (double)validCols) : 1.0;
    }
    if (outEdgeDelta) {
      double maxDelta = 0.0;
      if (segN[0] > 0 && segN[1] > 0 && segN[2] > 0) {
        for (int s = 0; s < 3; ++s) {
          segR[s] /= (double)segN[s]; segG[s] /= (double)segN[s]; segB[s] /= (double)segN[s];
        }
        for (int a = 0; a < 3; ++a) {
          for (int b = a + 1; b < 3; ++b) {
            double d = std::max({std::fabs(segR[a] - segR[b]), std::fabs(segG[a] - segG[b]), std::fabs(segB[a] - segB[b])});
            if (d > maxDelta) maxDelta = d;
          }
        }
      }
      *outEdgeDelta = maxDelta;
    }
  }

  if (outLuminance) {
    *outLuminance = SXRelativeLuminanceSRGB(avgR, avgG, avgB);
  }
  return [NSColor colorWithSRGBRed:avgR green:avgG blue:avgB alpha:1.0];
}

#pragma mark - SXTopEdgeColorSampler

static constexpr CFTimeInterval kMinSampleIntervalSec = 0.20;
static constexpr NSTimeInterval kScrollSettleDelaySec = 0.08;
static constexpr NSTimeInterval kResizeSettleDelaySec = 0.24;
static constexpr NSTimeInterval kPostLoadSettleDelaySec = 0.35;

@interface SXTopEdgeColorSampler () {
  dispatch_queue_t _decodeQueue;
  dispatch_source_t _debounceTimer;
  dispatch_source_t _resizeIdleTimer;

  BOOL _invalidated;
  BOOL _inFlight;
  BOOL _coalescedPending;
  BOOL _scrollGestureActive;
  BOOL _pinchActive;
  BOOL _resizeActive;
  uint64_t _generation;
  CFTimeInterval _lastSampleCompletedAt;
  BOOL _hasLastEmittedRGB;
  int _lastR;
  int _lastG;
  int _lastB;
}

@property (nonatomic, copy) CGFloat (^widthProvider)(void);
@property (nonatomic, copy) SXTopEdgeStripReadbackProvider readbackProvider;
@property (nonatomic, readwrite, strong, nullable) NSColor *lastSampledColor;
@property (nonatomic, readwrite) double lastRelativeLuminance;
@property (nonatomic, readwrite) double lastSampleUniformity;
@property (nonatomic, readwrite) double lastSampleEdgeDelta;
@property (nonatomic, readwrite) BOOL hasSampleForCurrentNavigation;
@property (nonatomic, readwrite) NSUInteger completedSampleCount;
@property (nonatomic, readwrite) NSUInteger suppressedDuringInteractionCount;

@end

@implementation SXTopEdgeColorSampler

- (instancetype)initWithWidthProvider:(CGFloat (^)(void))widthProvider
                     readbackProvider:(SXTopEdgeStripReadbackProvider)readbackProvider {
  self = [super init];
  if (self) {
    _widthProvider = [widthProvider copy];
    _readbackProvider = [readbackProvider copy];
    _automaticSamplingEnabled = YES;
    _stripHeightPoints = 3.0;
    _lastRelativeLuminance = 0.5;
    _decodeQueue = dispatch_queue_create(
        "com.safarium.top-edge-color-sampler",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                QOS_CLASS_UTILITY, 0));
  }
  return self;
}

- (void)dealloc {
  [self invalidate];
}

- (void)invalidate {
  _invalidated = YES;
  _generation++;
  _coalescedPending = NO;
  [self cancelDebounceTimer];
  [self cancelResizeIdleTimer];
  self.onColorSampled = nil;
}

- (BOOL)isUserInteracting {
  return _scrollGestureActive || _pinchActive || _resizeActive;
}

- (void)cancelDebounceTimer {
  if (_debounceTimer) {
    dispatch_source_cancel(_debounceTimer);
    _debounceTimer = nil;
  }
}

- (void)cancelResizeIdleTimer {
  if (_resizeIdleTimer) {
    dispatch_source_cancel(_resizeIdleTimer);
    _resizeIdleTimer = nil;
  }
}

- (void)scheduleSettledSampleWithDelay:(NSTimeInterval)delay {
  if (_invalidated || !self.automaticSamplingEnabled) {
    return;
  }
  [self cancelDebounceTimer];

  // Never schedule a sample while a scroll, momentum, pinch, or live resize is active.
  if ([self isUserInteracting]) {
    self.suppressedDuringInteractionCount++;
    return;
  }

  uint64_t scheduledGen = _generation;
  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  int64_t delayNs = (int64_t)(MAX(0.01, delay) * NSEC_PER_SEC);
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delayNs),
                            DISPATCH_TIME_FOREVER, 15 * NSEC_PER_MSEC);

  __weak SXTopEdgeColorSampler *weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    SXTopEdgeColorSampler *strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf cancelDebounceTimer];
    if (strongSelf->_invalidated || strongSelf->_generation != scheduledGen) {
      return;
    }
    if ([strongSelf isUserInteracting]) {
      strongSelf.suppressedDuringInteractionCount++;
      return;
    }
    [strongSelf requestSampleInternalWithStripHeight:strongSelf.stripHeightPoints
                                            explicit:NO
                                          completion:nil];
  });

  _debounceTimer = timer;
  dispatch_resume(timer);
}

#pragma mark - Interaction & Lifecycle Signals

- (void)notifyNavigationStarted {
  if (_invalidated) return;
  _generation++;
  _coalescedPending = NO;
  _hasLastEmittedRGB = NO;
  self.hasSampleForCurrentNavigation = NO;
  self.lastSampleUniformity = 1.0;
  self.lastSampleEdgeDelta = 0.0;
  [self cancelDebounceTimer];
}

- (void)notifyMainFrameLoadEnded {
  if (_invalidated || !self.automaticSamplingEnabled) return;
  if ([self isUserInteracting]) {
    self.suppressedDuringInteractionCount++;
    _coalescedPending = YES;
    return;
  }
  // Immediate initial sample on load completion, plus one post-paint settle check.
  [self requestSampleInternalWithStripHeight:self.stripHeightPoints
                                    explicit:NO
                                  completion:nil];
  [self scheduleSettledSampleWithDelay:kPostLoadSettleDelaySec];
}

- (void)notifyTabActivated {
  if (_invalidated || !self.automaticSamplingEnabled) return;
  if ([self isUserInteracting]) {
    self.suppressedDuringInteractionCount++;
    _coalescedPending = YES;
    return;
  }
  [self scheduleSettledSampleWithDelay:0.06];
}

- (void)notifyScrollGestureActive:(BOOL)active {
  if (_invalidated) return;
  BOOL wasActive = _scrollGestureActive;
  _scrollGestureActive = active;
  if (active) {
    // Cancel any pending sample immediately: ZERO readbacks during active scroll/momentum.
    _coalescedPending = NO;
    [self cancelDebounceTimer];
  } else if (wasActive && self.automaticSamplingEnabled) {
    // Gesture + momentum finished -> sample once after settle.
    [self scheduleSettledSampleWithDelay:kScrollSettleDelaySec];
  }
}

- (void)notifyScrollOffsetChanged {
  if (_invalidated || !self.automaticSamplingEnabled) return;
  if ([self isUserInteracting]) {
    // Trackpad gesture/momentum is actively running; defer until it ends.
    self.suppressedDuringInteractionCount++;
    [self cancelDebounceTimer];
    return;
  }
  // Mouse wheel or programmatic scroll without trackpad phase -> debounce until settled.
  [self scheduleSettledSampleWithDelay:kScrollSettleDelaySec];
}

- (void)notifyPinchActive:(BOOL)active {
  if (_invalidated) return;
  BOOL wasActive = _pinchActive;
  _pinchActive = active;
  if (active) {
    _coalescedPending = NO;
    [self cancelDebounceTimer];
  } else if (wasActive && self.automaticSamplingEnabled) {
    [self scheduleSettledSampleWithDelay:kScrollSettleDelaySec];
  }
}

- (void)notifyResizeActivity {
  if (_invalidated) return;
  _resizeActive = YES;
  _coalescedPending = NO;
  [self cancelDebounceTimer];
  [self cancelResizeIdleTimer];

  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  int64_t delayNs = (int64_t)(kResizeSettleDelaySec * NSEC_PER_SEC);
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delayNs),
                            DISPATCH_TIME_FOREVER, 20 * NSEC_PER_MSEC);

  __weak SXTopEdgeColorSampler *weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    SXTopEdgeColorSampler *strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf cancelResizeIdleTimer];
    strongSelf->_resizeActive = NO;
    if (!strongSelf->_invalidated && strongSelf.automaticSamplingEnabled &&
        ![strongSelf isUserInteracting]) {
      [strongSelf requestSampleInternalWithStripHeight:strongSelf.stripHeightPoints
                                              explicit:NO
                                            completion:nil];
    }
  });

  _resizeIdleTimer = timer;
  dispatch_resume(timer);
}

#pragma mark - Explicit Sampling

- (void)sampleNowWithStripHeightPoints:(CGFloat)stripHeightPoints
                            completion:(nullable SXTopEdgeSampleCompletion)completion {
  if (_invalidated) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, 0.5); });
    }
    return;
  }
  [self requestSampleInternalWithStripHeight:stripHeightPoints
                                    explicit:YES
                                  completion:completion];
}

#pragma mark - Single-In-Flight Coalesced Readback Pipeline

- (void)requestSampleInternalWithStripHeight:(CGFloat)rawStripHeight
                                    explicit:(BOOL)isExplicit
                                  completion:(nullable SXTopEdgeSampleCompletion)completion {
  if (_invalidated || !self.readbackProvider) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, 0.5); });
    }
    return;
  }

  if (!isExplicit && [self isUserInteracting]) {
    self.suppressedDuringInteractionCount++;
    return;
  }

  // Enforce minimum interval between automatic samples to keep compositor 100% jank-free.
  CFTimeInterval now = CACurrentMediaTime();
  if (!isExplicit && _lastSampleCompletedAt > 0.0) {
    CFTimeInterval elapsed = now - _lastSampleCompletedAt;
    if (elapsed < kMinSampleIntervalSec) {
      [self scheduleSettledSampleWithDelay:(kMinSampleIntervalSec - elapsed + 0.02)];
      return;
    }
  }

  // Strict single-in-flight coalescing.
  if (_inFlight) {
    if (!isExplicit) {
      _coalescedPending = YES;
      return;
    }
    // For explicit caller during an in-flight readback, return cached value immediately if fresh,
    // or wait for coalesced turn cleanly.
    if (self.lastSampledColor && (now - _lastSampleCompletedAt) < 0.15) {
      NSColor *cached = self.lastSampledColor;
      double lum = self.lastRelativeLuminance;
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, lum); });
      }
      return;
    }
  }

  _inFlight = YES;
  _coalescedPending = NO;
  uint64_t capturedGen = _generation;
  CGFloat stripHeight = MAX(2.0, MIN(4.0, rawStripHeight));
  // Estimate backing scale (~2x on Retina) for cropping top 2-4pt rows cleanly.
  CGFloat backingScale = [NSScreen mainScreen] ? [NSScreen mainScreen].backingScaleFactor : 2.0;
  if (backingScale < 1.0) backingScale = 2.0;
  size_t topStripPx = (size_t)std::max<double>(2.0, std::round(stripHeight * backingScale));
  // Web content is positioned natively below the toolbar, so y = 0 in the surface already meets the toolbar bottom.
  size_t topOffsetPx = 0;

  __weak SXTopEdgeColorSampler *weakSelf = self;
  self.readbackProvider(^(NSData * _Nullable imageData) {
    SXTopEdgeColorSampler *strongSelf = weakSelf;
    if (!strongSelf) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, 0.5); });
      }
      return;
    }

    // Crop top 2-4pt strip & compute trimmed-mean color + uniformity strictly OFF the main thread.
    dispatch_async(strongSelf->_decodeQueue, ^{
      double lum = 0.5;
      double uniformity = 1.0;
      double edgeDelta = 0.0;
      NSColor *color = imageData
                           ? SXTrimmedMeanStripColorAtOffset(imageData, topOffsetPx, topStripPx, &lum, &uniformity, &edgeDelta)
                           : nil;

      dispatch_async(dispatch_get_main_queue(), ^{
        SXTopEdgeColorSampler *s = weakSelf;
        if (!s) {
          if (completion) completion(color, lum);
          return;
        }

        s->_inFlight = NO;
        s->_lastSampleCompletedAt = CACurrentMediaTime();

        // Discard stale results from a previous navigation or closed tab.
        if (s->_invalidated || s->_generation != capturedGen) {
          if (completion) completion(nil, 0.5);
          return;
        }

        if (color) {
          s.completedSampleCount++;
          s.lastSampledColor = color;
          s.lastRelativeLuminance = lum;
          s.lastSampleUniformity = uniformity;
          s.lastSampleEdgeDelta = edgeDelta;
          s.hasSampleForCurrentNavigation = YES;

          NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
          int r = (int)llround(srgb.redComponent * 255.0);
          int g = (int)llround(srgb.greenComponent * 255.0);
          int b = (int)llround(srgb.blueComponent * 255.0);
          BOOL changed = !s->_hasLastEmittedRGB ||
                         abs(r - s->_lastR) > 1 ||
                         abs(g - s->_lastG) > 1 ||
                         abs(b - s->_lastB) > 1;
          if (changed || isExplicit) {
            s->_hasLastEmittedRGB = YES;
            s->_lastR = r;
            s->_lastG = g;
            s->_lastB = b;
            if (s.onColorSampled) {
              s.onColorSampled(color, lum);
            }
          }
        }

        if (completion) {
          completion(color, lum);
        }

        // If another settled trigger coalesced while we were in flight and user is still idle, run once.
        if (s->_coalescedPending && !s->_invalidated && ![s isUserInteracting]) {
          s->_coalescedPending = NO;
          [s scheduleSettledSampleWithDelay:kMinSampleIntervalSec];
        }
      });
    });
  });
}

@end
