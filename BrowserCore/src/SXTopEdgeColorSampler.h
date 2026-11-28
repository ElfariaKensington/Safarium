// SXTopEdgeColorSampler.h
// Dedicated zero-jank, pixel-only top-edge color sampler for BrowserCore.
// Strictly ignores <meta name="theme-color">, performs ZERO work during active
// scroll/momentum/pinch/resize, decodes tiny 0.25x top strips off the main thread,
// and coalesces requests with strict single-in-flight & generation cancellation.

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <functional>
#include <string>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SXTopEdgeSampleCompletion)(NSColor * _Nullable color, double relativeLuminance);

/// Provider callback invoked on the main thread to request a read-only surface readback
/// (without CDP `clip` or `DeviceEmulationParams` mutation) from Chromium's compositor.
typedef void (^SXTopEdgeStripReadbackProvider)(
    void (^resultHandler)(NSData * _Nullable imageData));

@interface SXTopEdgeColorSampler : NSObject

@property (nonatomic, assign) BOOL automaticSamplingEnabled;
@property (nonatomic, assign) CGFloat stripHeightPoints;
@property (nonatomic, copy, nullable) CGFloat (^topOffsetPointsProvider)(void);
@property (nonatomic, copy, nullable) CGFloat (^backingScaleProvider)(void);
@property (nonatomic, readonly, strong, nullable) NSColor *lastSampledColor;
@property (nonatomic, readonly) double lastRelativeLuminance;
/// Fraction [0.0, 1.0] of horizontal columns in the last sampled top strip matching the strip's trimmed mean.
@property (nonatomic, readonly) double lastSampleUniformity;
/// Maximum sRGB channel difference [0.0, 1.0] across left, center, and right thirds of the last sampled top strip.
@property (nonatomic, readonly) double lastSampleEdgeDelta;
/// Whether at least one GPU pixel sample has completed since the last navigation started.
@property (nonatomic, readonly) BOOL hasSampleForCurrentNavigation;

/// Diagnostic counters (useful for verifying zero work during active scroll/momentum).
@property (nonatomic, readonly) NSUInteger completedSampleCount;
@property (nonatomic, readonly) NSUInteger suppressedDuringInteractionCount;

/// Invoked on the main thread when a new distinct top-edge color is sampled.
@property (nonatomic, copy, nullable) void (^onColorSampled)(NSColor *color, double relativeLuminance);

- (instancetype)initWithWidthProvider:(CGFloat (^)(void))widthProvider
                     readbackProvider:(SXTopEdgeStripReadbackProvider)readbackProvider;

#pragma mark - Lifecycle & Interaction Signals

/// Cancels any pending timers & invalidates in-flight callbacks (call on close/detach).
- (void)invalidate;

/// Bumps navigation generation and cancels pending/stale samples when navigating to a new URL.
- (void)notifyNavigationStarted;

/// Triggers a clean sample upon main-frame load completion (plus one post-paint settle check).
- (void)notifyMainFrameLoadEnded;

/// Triggers a clean sample when a tab becomes visible/active (if not actively interacting).
- (void)notifyTabActivated;

/// Marks active trackpad scroll / momentum gesture state.
/// While active, pending timers are cancelled and ZERO readbacks are issued.
- (void)notifyScrollGestureActive:(BOOL)active;

/// Called when scrollY updates. Cancels pending debounce while moving and schedules a single
/// settled sample (~220ms) once scroll & momentum are idle.
- (void)notifyScrollOffsetChanged;

/// Marks active pinch-zoom state. Suppresses sampling during pinch and schedules settle after.
- (void)notifyPinchActive:(BOOL)active;

/// Marks live view resize activity. Suppresses sampling during resize and schedules settle after.
- (void)notifyResizeActivity;

#pragma mark - Explicit One-Shot Sampling

/// Performs an explicit pixel sample of the top `stripHeightPoints` (clamped 2..4pt),
/// strictly ignoring `<meta name="theme-color">`, invoking `completion` on the main thread.
- (void)sampleNowWithStripHeightPoints:(CGFloat)stripHeightPoints
                            completion:(nullable SXTopEdgeSampleCompletion)completion;

@end

/// Computes WCAG 2.1 relative luminance in [0.0, 1.0] for an sRGB color.
double SXRelativeLuminanceSRGB(double r, double g, double b);

/// Decodes surface image bytes (JPEG/PNG) off the main thread, cropping ONLY the top
/// `topStripPixels` rows and computing a trimmed-mean sRGB color (dropping top/bottom 10%
/// luminance outliers so corner logos/borders never skew the adaptive tint).
NSColor * _Nullable SXTrimmedMeanTopStripColorFromImageData(NSData *imageData,
                                                            size_t topStripPixels,
                                                            double * _Nullable outLuminance);

NS_ASSUME_NONNULL_END
