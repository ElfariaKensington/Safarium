// SXExtensionManager.mm
// Persistent Chrome Web Store MV3 extension manager + real Chromium chrome-extension:// popup host.

#import "SXExtensionManager.h"
#import "SXInternal.h"

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>

/// Resolves a manifest-relative path inside `baseDir` and returns nil when it would escape it
/// (`..` components, absolute paths, symlinks pointing outside). Used for every manifest-controlled path.
/// Per-extension bridge credentials: key = first 16 hex chars of SHA-256(extension dir); token = HMAC-SHA256(globalToken, key).
static std::string SXHexString(const unsigned char *bytes, size_t n) {
  static const char *kHex = "0123456789abcdef";
  std::string out;
  out.reserve(n * 2);
  for (size_t i = 0; i < n; i++) { out.push_back(kHex[bytes[i] >> 4]); out.push_back(kHex[bytes[i] & 0xF]); }
  return out;
}
static std::string SXBridgeKeyForDirectory(NSString *dir) {
  NSData *d = [dir dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  unsigned char h[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, h);
  return SXHexString(h, 8);
}
static std::string SXBridgeTokenForKey(const std::string &globalToken, const std::string &key) {
  unsigned char mac[CC_SHA256_DIGEST_LENGTH];
  CCHmac(kCCHmacAlgSHA256, globalToken.data(), globalToken.size(), key.data(), key.size(), mac);
  return SXHexString(mac, sizeof(mac));
}
static bool SXConstantTimeEquals(const std::string &a, const std::string &b) {
  if (a.size() != b.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); i++) diff |= (unsigned char)(a[i] ^ b[i]);
  return diff == 0;
}
/// True when the extension's manifest grants it access to tab URLs/screenshots (tabs, activeTab or <all_urls>).
static bool SXManifestGrantsTabAccess(NSString *dir) {
  NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"manifest.json"]];
  NSDictionary *m = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![m isKindOfClass:[NSDictionary class]]) return false;
  for (NSString *k in @[ @"permissions", @"host_permissions", @"optional_permissions" ]) {
    NSArray *arr = [m[k] isKindOfClass:[NSArray class]] ? m[k] : nil;
    for (id v in arr) {
      if (![v isKindOfClass:[NSString class]]) continue;
      if ([v isEqualToString:@"tabs"] || [v isEqualToString:@"activeTab"] || [v isEqualToString:@"<all_urls>"] ||
          [v isEqualToString:@"*://*/*"] || [v isEqualToString:@"http://*/*"] || [v isEqualToString:@"https://*/*"]) return true;
    }
  }
  return false;
}

/// Resolves a manifest-relative path inside `baseDir` and returns nil when it would escape it.
static NSString * _Nullable SXContainedPath(NSString *baseDir, NSString *rel) {
  if (![baseDir isKindOfClass:[NSString class]] || ![rel isKindOfClass:[NSString class]] || rel.length == 0) return nil;
  NSString *trimmed = [rel stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
  if (trimmed.length == 0) return nil;
  NSString *base = [[baseDir stringByStandardizingPath] stringByResolvingSymlinksInPath];
  NSString *cand = [[[base stringByAppendingPathComponent:trimmed] stringByStandardizingPath] stringByResolvingSymlinksInPath];
  NSString *prefix = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
  return [cand hasPrefix:prefix] ? cand : nil;
}
#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

NSNotificationName const SXEngineRuntimeDidUpdateExtensionsNotification =
    @"SXEngineRuntimeDidUpdateExtensionsNotification";
NSNotificationName const SXExtensionPopupPreferredSizeDidChangeNotification =
    @"SXExtensionPopupPreferredSizeDidChangeNotification";
NSNotificationName const SXExtensionPopupShouldCloseNotification =
    @"SXExtensionPopupShouldCloseNotification";

#pragma mark - Chromium Extension ID & CRX3 Parsing Helpers

static NSString *SXChromiumIDFromBytes(const void *bytes, size_t len) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes, (CC_LONG)len, digest);
  char out[33];
  for (int i = 0; i < 16; ++i) {
    out[i * 2] = 'a' + ((digest[i] >> 4) & 0x0F);
    out[i * 2 + 1] = 'a' + (digest[i] & 0x0F);
  }
  out[32] = '\0';
  return [NSString stringWithUTF8String:out];
}

static NSString *SXChromiumIDFromPath(NSString *path) {
  char resolved[PATH_MAX];
  const char *cpath = realpath(path.UTF8String, resolved) ? resolved : path.UTF8String;
  return SXChromiumIDFromBytes(cpath, strlen(cpath));
}

static BOOL SXReadProtobufVarint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *outVal) {
  uint64_t result = 0;
  int shift = 0;
  while (*pos < len && shift < 64) {
    uint8_t b = buf[(*pos)++];
    result |= (uint64_t)(b & 0x7F) << shift;
    if ((b & 0x80) == 0) {
      *outVal = result;
      return YES;
    }
    shift += 7;
  }
  return NO;
}

/// Scans CRX3 CrxFileHeader protobuf for an AsymmetricKeyProof public_key (field 2/3 -> sub-field 1)
/// matching `expectedStoreID` (or returns the first RSA/ECDSA public_key if `expectedStoreID` is nil).
static NSData * _Nullable SXExtractCRX3PublicKey(const uint8_t *hdr,
                                                 size_t hdrLen,
                                                 NSString * _Nullable expectedStoreID) {
  NSData *firstKey = nil;
  size_t pos = 0;
  while (pos < hdrLen) {
    uint64_t tag = 0;
    if (!SXReadProtobufVarint(hdr, hdrLen, &pos, &tag)) break;
    uint32_t fieldNum = (uint32_t)(tag >> 3);
    uint32_t wireType = (uint32_t)(tag & 0x07);
    if (wireType == 2) {
      uint64_t slen = 0;
      if (!SXReadProtobufVarint(hdr, hdrLen, &pos, &slen) || pos + slen > hdrLen) break;
      const uint8_t *sub = hdr + pos;
      pos += (size_t)slen;
      // CrxFileHeader: field 2 = sha256_with_rsa, field 3 = sha256_with_ecdsa
      if (fieldNum == 2 || fieldNum == 3) {
        size_t spos = 0;
        while (spos < slen) {
          uint64_t stag = 0;
          if (!SXReadProtobufVarint(sub, (size_t)slen, &spos, &stag)) break;
          uint32_t sfield = (uint32_t)(stag >> 3);
          uint32_t swire = (uint32_t)(stag & 0x07);
          if (swire == 2) {
            uint64_t klen = 0;
            if (!SXReadProtobufVarint(sub, (size_t)slen, &spos, &klen) || spos + klen > slen) break;
            if (sfield == 1 && klen > 32) {
              NSData *pubKey = [NSData dataWithBytes:(sub + spos) length:(NSUInteger)klen];
              if (!firstKey) firstKey = pubKey;
              if (expectedStoreID.length == 32) {
                NSString *derived = SXChromiumIDFromBytes(pubKey.bytes, pubKey.length);
                if ([derived caseInsensitiveCompare:expectedStoreID] == NSOrderedSame) {
                  return pubKey;
                }
              }
            }
            spos += (size_t)klen;
          } else if (swire == 0) {
            uint64_t skip = 0;
            if (!SXReadProtobufVarint(sub, (size_t)slen, &spos, &skip)) break;
          } else {
            break;
          }
        }
      }
    } else if (wireType == 0) {
      uint64_t skip = 0;
      if (!SXReadProtobufVarint(hdr, hdrLen, &pos, &skip)) break;
    } else if (wireType == 5) {
      pos += 4;
    } else if (wireType == 1) {
      pos += 8;
    } else {
      break;
    }
  }
  return firstKey;
}

static NSData * _Nullable SXExtractZipFromCRXData(NSData *rawData,
                                                  NSString * _Nullable expectedStoreID,
                                                  NSData * _Nullable * _Nullable outPublicKey,
                                                  NSError **outError) {
  if (rawData.length < 16) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"com.safarium.Extensions"
                                      code:2001
                                  userInfo:@{NSLocalizedDescriptionKey : @"CRX/ZIP payload too short"}];
    }
    return nil;
  }
  const uint8_t *b = (const uint8_t *)rawData.bytes;
  size_t len = rawData.length;

  // Already a raw ZIP?
  if (b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04) {
    return rawData;
  }

  if (memcmp(b, "Cr24", 4) == 0) {
    uint32_t version = 0;
    memcpy(&version, b + 4, 4);
    if (version == 3) {
      uint32_t hdrSize = 0;
      memcpy(&hdrSize, b + 8, 4);
      size_t zipOffset = 12 + (size_t)hdrSize;
      if (zipOffset < len) {
        if (outPublicKey) {
          *outPublicKey = SXExtractCRX3PublicKey(b + 12, hdrSize, expectedStoreID);
        }
        return [rawData subdataWithRange:NSMakeRange(zipOffset, len - zipOffset)];
      }
    } else if (version == 2) {
      uint32_t pubKeyLen = 0, sigLen = 0;
      memcpy(&pubKeyLen, b + 8, 4);
      memcpy(&sigLen, b + 12, 4);
      size_t zipOffset = 16 + (size_t)pubKeyLen + (size_t)sigLen;
      if (zipOffset < len) {
        if (outPublicKey && pubKeyLen > 0) {
          *outPublicKey = [NSData dataWithBytes:(b + 16) length:pubKeyLen];
        }
        return [rawData subdataWithRange:NSMakeRange(zipOffset, len - zipOffset)];
      }
    }
  }

  // Fallback scan for PK\x03\x04 ZIP header
  const uint8_t pk[4] = {0x50, 0x4B, 0x03, 0x04};
  NSData *needle = [NSData dataWithBytes:pk length:4];
  NSRange r = [rawData rangeOfData:needle options:0 range:NSMakeRange(0, len)];
  if (r.location != NSNotFound) {
    return [rawData subdataWithRange:NSMakeRange(r.location, len - r.location)];
  }

  if (outError) {
    *outError = [NSError errorWithDomain:@"com.safarium.Extensions"
                                    code:2002
                                userInfo:@{NSLocalizedDescriptionKey : @"Unrecognized CRX/ZIP archive format"}];
  }
  return nil;
}

static BOOL SXRunUnzipTool(NSString *zipPath, NSString *destDir, NSError **outError) {
  auto runTool = ^BOOL(NSString *execPath, NSArray<NSString *> *args) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:execPath];
    task.arguments = args;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
      return NO;
    }
    [task waitUntilExit];
    return task.terminationStatus == 0;
  };

  if (runTool(@"/usr/bin/ditto", @[ @"-xk", zipPath, destDir ])) {
    return YES;
  }
  // Fallback to unzip (handles CRX-stripped ZIPs with non-standard offsets or comments)
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:destDir error:nil];
  [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
  if (runTool(@"/usr/bin/unzip", @[ @"-oq", zipPath, @"-d", destDir ])) {
    return YES;
  }
  if (outError) {
    *outError = [NSError errorWithDomain:@"com.safarium.Extensions"
                                    code:2004
                                userInfo:@{NSLocalizedDescriptionKey : @"Failed to unpack extension archive"}];
  }
  return NO;
}

static BOOL SXUnpackZipDataToDirectory(NSData *zipData, NSString *destDir, NSError **outError) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *tmpZip = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"safarium-ext-%@.zip", [[NSUUID UUID] UUIDString]]];
  if (![zipData writeToFile:tmpZip atomically:YES]) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"com.safarium.Extensions"
                                      code:2003
                                  userInfo:@{NSLocalizedDescriptionKey : @"Failed to write temporary ZIP"}];
    }
    return NO;
  }

  [fm removeItemAtPath:destDir error:nil];
  [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

  BOOL ok = SXRunUnzipTool(tmpZip, destDir, outError);
  [fm removeItemAtPath:tmpZip error:nil];
  if (!ok) {
    [fm removeItemAtPath:destDir error:nil];
    return NO;
  }

  // Unwrap up to 3 levels of nested wrapper folders or nested .zip/.crx archives
  // (e.g. a .crx that is a ZIP containing an inner extension .zip or subfolder).
  NSString *manifestPath = [destDir stringByAppendingPathComponent:@"manifest.json"];
  for (int depth = 0; depth < 3 && ![fm fileExistsAtPath:manifestPath]; ++depth) {
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:destDir error:nil];
    NSMutableArray<NSString *> *realEntries = [NSMutableArray array];
    for (NSString *e in entries) {
      if (![e hasPrefix:@"."] && ![e isEqualToString:@"__MACOSX"]) {
        [realEntries addObject:e];
      }
    }
    if (realEntries.count != 1) {
      break;
    }

    NSString *onlyName = realEntries.firstObject;
    NSString *innerPath = [destDir stringByAppendingPathComponent:onlyName];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:innerPath isDirectory:&isDir]) {
      break;
    }

    if (isDir) {
      NSString *stagingDir = [NSTemporaryDirectory()
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"safarium-flatten-%@", [[NSUUID UUID] UUIDString]]];
      if (![fm moveItemAtPath:innerPath toPath:stagingDir error:nil]) {
        break;
      }
      for (NSString *sub in [fm contentsOfDirectoryAtPath:stagingDir error:nil]) {
        [fm moveItemAtPath:[stagingDir stringByAppendingPathComponent:sub]
                    toPath:[destDir stringByAppendingPathComponent:sub]
                     error:nil];
      }
      [fm removeItemAtPath:stagingDir error:nil];
      continue;
    }

    NSString *ext = onlyName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"crx"]) {
      NSData *nestedRaw = [NSData dataWithContentsOfFile:innerPath];
      if (!nestedRaw) break;
      NSData *nestedZip = SXExtractZipFromCRXData(nestedRaw, nil, nil, nil);
      if (!nestedZip) break;
      NSString *nestedTmp = [NSTemporaryDirectory()
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"safarium-nested-%@.zip", [[NSUUID UUID] UUIDString]]];
      if (![nestedZip writeToFile:nestedTmp atomically:YES]) break;

      [fm removeItemAtPath:destDir error:nil];
      [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
      BOOL nestedOK = SXRunUnzipTool(nestedTmp, destDir, outError);
      [fm removeItemAtPath:nestedTmp error:nil];
      if (!nestedOK) {
        [fm removeItemAtPath:destDir error:nil];
        return NO;
      }
      continue;
    }

    break;
  }

  if (![fm fileExistsAtPath:manifestPath]) {
    [fm removeItemAtPath:destDir error:nil];
    if (outError) {
      *outError = [NSError errorWithDomain:@"com.safarium.Extensions"
                                      code:2005
                                  userInfo:@{NSLocalizedDescriptionKey : @"Extension package missing manifest.json"}];
    }
    return NO;
  }
  return YES;
}

static NSString *SXResolveLocalizedMessage(NSString *extDir,
                                           NSDictionary *manifest,
                                           NSString *rawValue) {
  if (![rawValue isKindOfClass:[NSString class]] || rawValue.length == 0) {
    return @"";
  }
  if (![rawValue hasPrefix:@"__MSG_"] || ![rawValue hasSuffix:@"__"] || rawValue.length <= 8) {
    return rawValue;
  }
  NSString *msgKey = [[rawValue substringWithRange:NSMakeRange(6, rawValue.length - 8)] lowercaseString];
  NSMutableArray<NSString *> *locales = [NSMutableArray array];
  if ([manifest[@"default_locale"] isKindOfClass:[NSString class]]) {
    [locales addObject:manifest[@"default_locale"]];
  }
  [locales addObjectsFromArray:@[ @"en", @"en_US", @"en_GB" ]];

  for (NSString *loc in locales) {
    NSString *msgPath = [[[extDir stringByAppendingPathComponent:@"_locales"]
        stringByAppendingPathComponent:loc] stringByAppendingPathComponent:@"messages.json"];
    NSData *data = [NSData dataWithContentsOfFile:msgPath];
    if (!data) continue;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) continue;
    for (NSString *k in dict) {
      if ([[k lowercaseString] isEqualToString:msgKey]) {
        NSDictionary *entry = dict[k];
        if ([entry isKindOfClass:[NSDictionary class]] &&
            [entry[@"message"] isKindOfClass:[NSString class]]) {
          return entry[@"message"];
        }
      }
    }
  }
  return rawValue;
}

static NSString * _Nullable SXPickBestIconPath(NSString *extDir, id iconSpec) {
  NSString *rel = nil;
  if ([iconSpec isKindOfClass:[NSString class]]) {
    rel = iconSpec;
  } else if ([iconSpec isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dict = (NSDictionary *)iconSpec;
    NSArray<NSString *> *preferred = @[ @"128", @"96", @"64", @"48", @"32", @"24", @"19", @"16" ];
    for (NSString *sz in preferred) {
      if ([dict[sz] isKindOfClass:[NSString class]]) {
        rel = dict[sz];
        break;
      }
    }
    if (!rel) {
      for (id v in dict.allValues) {
        if ([v isKindOfClass:[NSString class]]) {
          rel = v;
          break;
        }
      }
    }
  }
  if (!rel.length) return nil;
  NSString *clean = [rel stringByTrimmingCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@"/"]];
  NSString *full = [extDir stringByAppendingPathComponent:clean];
  return [[NSFileManager defaultManager] fileExistsAtPath:full] ? full : nil;
}

#pragma mark - SXExtensionContextMenuItem & SXExtensionItem

@implementation SXExtensionContextMenuItem

- (instancetype)initWithItemID:(NSString *)itemID
                      parentID:(nullable NSString *)parentID
                         title:(NSString *)title
                     separator:(BOOL)separator
                       enabled:(BOOL)enabled
                       checked:(BOOL)checked
                      children:(NSArray<SXExtensionContextMenuItem *> *)children {
  self = [super init];
  if (self) {
    _itemID = [itemID copy] ?: @"";
    _parentID = [parentID copy];
    _title = [title copy] ?: @"";
    _separator = separator;
    _enabled = enabled;
    _checked = checked;
    _children = [children copy] ?: @[];
  }
  return self;
}

@end

static NSColor * _Nullable SXColorFromBadgeSpec(id spec) {
  if ([spec isKindOfClass:[NSArray class]]) {
    NSArray *arr = (NSArray *)spec;
    if (arr.count >= 3) {
      CGFloat r = [arr[0] doubleValue] / 255.0;
      CGFloat g = [arr[1] doubleValue] / 255.0;
      CGFloat b = [arr[2] doubleValue] / 255.0;
      CGFloat a = (arr.count >= 4) ? ([arr[3] doubleValue] / 255.0) : 1.0;
      if (a <= 0.001) return nil;
      return [NSColor colorWithSRGBRed:MAX(0, MIN(1, r))
                                 green:MAX(0, MIN(1, g))
                                  blue:MAX(0, MIN(1, b))
                                 alpha:MAX(0, MIN(1, a))];
    }
    return nil;
  }
  if (![spec isKindOfClass:[NSString class]]) return nil;
  NSString *s = [(NSString *)spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!s.length) return nil;
  if ([s hasPrefix:@"#"]) {
    NSString *hex = [s substringFromIndex:1];
    unsigned int val = 0;
    NSScanner *sc = [NSScanner scannerWithString:hex];
    if (![sc scanHexInt:&val]) return nil;
    if (hex.length == 3) {
      CGFloat r = ((val >> 8) & 0xF) / 15.0;
      CGFloat g = ((val >> 4) & 0xF) / 15.0;
      CGFloat b = (val & 0xF) / 15.0;
      return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    } else if (hex.length == 6) {
      CGFloat r = ((val >> 16) & 0xFF) / 255.0;
      CGFloat g = ((val >> 8) & 0xFF) / 255.0;
      CGFloat b = (val & 0xFF) / 255.0;
      return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    } else if (hex.length == 8) {
      CGFloat r = ((val >> 24) & 0xFF) / 255.0;
      CGFloat g = ((val >> 16) & 0xFF) / 255.0;
      CGFloat b = ((val >> 8) & 0xFF) / 255.0;
      CGFloat a = (val & 0xFF) / 255.0;
      return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
    }
  } else if ([s hasPrefix:@"rgb"]) {
    NSRange open = [s rangeOfString:@"("];
    NSRange close = [s rangeOfString:@")"];
    if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
      NSString *inner = [s substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
      NSArray<NSString *> *parts = [inner componentsSeparatedByString:@","];
      if (parts.count >= 3) {
        CGFloat r = [parts[0] doubleValue] / 255.0;
        CGFloat g = [parts[1] doubleValue] / 255.0;
        CGFloat b = [parts[2] doubleValue] / 255.0;
        CGFloat a = (parts.count >= 4) ? [parts[3] doubleValue] : 1.0;
        return [NSColor colorWithSRGBRed:MAX(0, MIN(1, r))
                                   green:MAX(0, MIN(1, g))
                                    blue:MAX(0, MIN(1, b))
                                   alpha:MAX(0, MIN(1, a))];
      }
    }
  }
  return nil;
}

@implementation SXExtensionItem

- (instancetype)initWithExtensionID:(NSString *)extensionID
                            storeID:(nullable NSString *)storeID
                               name:(NSString *)name
                            version:(NSString *)version
               extensionDescription:(nullable NSString *)extensionDescription
                               icon:(nullable NSImage *)icon
                          badgeText:(nullable NSString *)badgeText
                         badgeColor:(nullable NSColor *)badgeColor
                           popupURL:(nullable NSURL *)popupURL
                        installPath:(NSString *)installPath
                            enabled:(BOOL)enabled
                     allowInPrivate:(BOOL)allowInPrivate {
  self = [super init];
  if (self) {
    _extensionID = [extensionID copy] ?: @"";
    _storeID = [storeID copy];
    _name = [name copy] ?: @"Extension";
    _version = [version copy] ?: @"1.0";
    _extensionDescription = [extensionDescription copy];
    _icon = icon;
    _badgeText = [badgeText copy];
    _badgeColor = badgeColor;
    _popupURL = popupURL;
    _installPath = [installPath copy] ?: @"";
    _enabled = enabled;
    _allowInPrivate = allowInPrivate;
  }
  return self;
}

@end

#pragma mark - Extension Popup CefClient & Host View

static SXBrowserTab * _Nullable SXFindActiveVisibleTab(void) {
  NSArray<SXBrowserTab *> *tabs = [[SXEngineRuntime sharedRuntime] activeTabs];
  for (SXBrowserTab *t in tabs) {
    if (!t.contentView.isHidden && t.contentView.window != nil) {
      return t;
    }
  }
  for (SXBrowserTab *t in tabs) {
    if (!t.contentView.isHidden) {
      return t;
    }
  }
  return tabs.firstObject;
}

class SXExtensionPopupClient : public CefClient,
                               public CefLifeSpanHandler,
                               public CefDisplayHandler,
                               public CefLoadHandler,
                               public CefRequestHandler {
 public:
  SXExtensionPopupClient(NSView *hostView,
                         NSString *extensionID,
                         double initialWidth,
                         double initialHeight,
                         BOOL isPopout = NO)
      : host_view_(hostView),
        extension_id_([extensionID copy] ?: @""),
        initial_width_(std::max(240.0, initialWidth)),
        initial_height_(std::max(120.0, initialHeight)),
        is_popout_(isPopout ? true : false) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void PostPreferredSize(double width, double height, bool fromDomMeasurement) {
    if (is_popout_) {
      return;
    }
    double clampedW = std::max(240.0, std::min(600.0, std::ceil(width)));
    double clampedH = std::max(120.0, std::min(600.0, std::ceil(height)));
    bool firstDomReady = false;
    if (fromDomMeasurement) {
      has_painted_content_ = true;
      if (!has_notified_content_ready_) {
        has_notified_content_ready_ = true;
        firstDomReady = true;
      }
    } else if (!has_painted_content_ && clampedW < initial_width_ - 2.0) {
      // Do NOT let Blink's premature EnableAutoResize collapse a `body { width: 100% }`
      // loading-spinner document (like Bitwarden's `#loading`) down to a skinny 200-240px
      // column before Angular/JS mounts real content.
      return;
    }
    if (!firstDomReady) {
      if (std::abs(clampedW - last_width_) < 4.0 && std::abs(clampedH - last_height_) < 4.0) {
        return;
      }
      if (resize_count_ >= 10) {
        return;
      }
      if (resize_count_ >= 2 &&
          std::abs(clampedW - prev_width_) <= 4.0 &&
          std::abs(clampedH - prev_height_) <= 4.0) {
        return;
      }
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      if (last_resize_time_ > 0.0 && (now - last_resize_time_) < 0.12) {
        return;
      }
      last_resize_time_ = now;
      resize_count_++;
    }
    prev_width_ = last_width_;
    prev_height_ = last_height_;
    last_width_ = clampedW;
    last_height_ = clampedH;
    NSString *extId = extension_id_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
          postNotificationName:SXExtensionPopupPreferredSizeDidChangeNotification
                        object:[SXEngineRuntime sharedRuntime]
                      userInfo:@{
                        @"extensionID" : extId ?: @"",
                        @"width" : @(clampedW),
                        @"height" : @(clampedH),
                        @"contentReady" : @(fromDomMeasurement),
                      }];
    });
  }

  bool OnAutoResize(CefRefPtr<CefBrowser> browser, const CefSize& new_size) override {
    CEF_REQUIRE_UI_THREAD();
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtPopup] OnAutoResize(%dx%d) painted=%d\n",
              new_size.width, new_size.height, has_painted_content_ ? 1 : 0);
      fflush(stderr);
    }
    if (new_size.width > 0 && new_size.height > 0) {
      PostPreferredSize((double)new_size.width, (double)new_size.height, false);
    }
    return true;
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtPopup console %d] %s (%s:%d)\n",
              (int)level, message.ToString().c_str(), source.ToString().c_str(), line);
      fflush(stderr);
    }
    return false;
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    CEF_REQUIRE_UI_THREAD();
    if (!message) return false;
    const std::string name = message->GetName().ToString();
    if (name == "sx.ext_popup_size") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 2) {
        PostPreferredSize(args->GetDouble(0), args->GetDouble(1), true);
      }
      return true;
    }
    if (name == "sx.ext_tab_reload") {
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *activeTab = SXFindActiveVisibleTab();
        [activeTab reload];
      });
      return true;
    }
    if (name == "sx.ext_tab_create") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 1) {
        std::string urlStr = args->GetString(0).ToString();
        NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
        NSURL *url = nsUrl.length > 0 ? [NSURL URLWithString:nsUrl] : nil;
        if (url) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
          });
        }
      }
      return true;
    }
    if (name == "sx.ext_window_create") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 1) {
        std::string urlStr = args->GetString(0).ToString();
        double reqW = args->GetSize() >= 2 ? args->GetDouble(1) : 380.0;
        double reqH = args->GetSize() >= 3 ? args->GetDouble(2) : 630.0;
        double reqL = args->GetSize() >= 4 ? args->GetDouble(3) : -1.0;
        double reqT = args->GetSize() >= 5 ? args->GetDouble(4) : -1.0;
        NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
        NSURL *url = nsUrl.length > 0 ? [NSURL URLWithString:nsUrl] : nil;
        NSString *extId = extension_id_;
        if (url) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:SXExtensionPopupShouldCloseNotification
                              object:[SXEngineRuntime sharedRuntime]
                            userInfo:@{@"extensionID" : extId ?: @""}];
            [[SXExtensionManager sharedManager] openPopoutWindowForExtensionID:extId ?: @""
                                                                           url:url
                                                                         width:(CGFloat)reqW
                                                                        height:(CGFloat)reqH
                                                                          left:(CGFloat)reqL
                                                                           top:(CGFloat)reqT];
          });
        }
      }
      return true;
    }
    if (name == "sx.ext_window_close") {
      NSView *strongHost = host_view_;
      NSString *extId = extension_id_;
      bool wasPopout = is_popout_;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (wasPopout) {
          NSWindow *win = strongHost.window;
          if (win) {
            [[SXExtensionManager sharedManager] closePopoutWindow:win];
          }
        } else {
          [[NSNotificationCenter defaultCenter]
              postNotificationName:SXExtensionPopupShouldCloseNotification
                            object:[SXEngineRuntime sharedRuntime]
                          userInfo:@{@"extensionID" : extId ?: @""}];
        }
      });
      return true;
    }
    return false;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    CEF_REQUIRE_UI_THREAD();
    if (target_disposition != CEF_WOD_CURRENT_TAB) {
      std::string urlStr = target_url.ToString();
      if (!urlStr.empty()) {
        NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
        NSURL *url = nsUrl.length > 0 ? [NSURL URLWithString:nsUrl] : nil;
        if (url) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
          });
        }
      }
      return true;
    }
    return false;
  }

  static NSView * _Nullable FindPopupRenderWidgetView(NSView *root) {
    if (!root) return nil;
    for (NSView *sub in root.subviews) {
      NSString *clsName = NSStringFromClass([sub class]);
      if ([clsName containsString:@"RenderWidgetHostView"]) {
        return sub;
      }
      NSView *nested = FindPopupRenderWidgetView(sub);
      if (nested) return nested;
    }
    return root.subviews.firstObject;
  }

  void FocusHostView(NSView *strongHost) {
    if (!strongHost || !strongHost.window) return;
    NSView *rwhv = FindPopupRenderWidgetView(strongHost);
    if (rwhv && strongHost.window.isKeyWindow) {
      [strongHost.window makeFirstResponder:rwhv];
    }
  }

  static void MakeLayerTreeNonOpaque(CALayer *layer) {
    if (!layer) return;
    layer.opaque = NO;
    NSString *clsName = NSStringFromClass([layer class]);
    if (![clsName containsString:@"LayerHost"]) {
      layer.backgroundColor = NSColor.clearColor.CGColor;
    }
    for (CALayer *sub in layer.sublayers) {
      MakeLayerTreeNonOpaque(sub);
    }
  }

  static void MakeViewTreeNonOpaque(NSView *view) {
    if (!view) return;
    if (view.layer) {
      MakeLayerTreeNonOpaque(view.layer);
    }
    for (NSView *sub in view.subviews) {
      MakeViewTreeNonOpaque(sub);
    }
  }

  void ApplyTransparentCanvasIfNeeded(CefRefPtr<CefBrowser> browser) {
    if (is_popout_ || !browser || !browser->GetHost()) return;
    CefRefPtr<CefDictionaryValue> color = CefDictionaryValue::Create();
    color->SetInt("r", 0);
    color->SetInt("g", 0);
    color->SetInt("b", 0);
    color->SetDouble("a", 0.0);
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetDictionary("color", color);
    browser->GetHost()->ExecuteDevToolsMethod(
        0, "Emulation.setDefaultBackgroundColorOverride", params);

    NSView *strongHost = host_view_;
    if (strongHost) {
      dispatch_async(dispatch_get_main_queue(), ^{
        MakeViewTreeNonOpaque(strongHost);
      });
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
    browser_ = browser;
    NSView *strongHost = host_view_;
    if (strongHost && browser && browser->GetHost()) {
      NSView *cefView =
          CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      if (cefView) {
        cefView.frame = strongHost.bounds;
        cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      }
      ApplyTransparentCanvasIfNeeded(browser);
      browser->GetHost()->NotifyScreenInfoChanged();
      FocusHostView(strongHost);
      browser->GetHost()->SetFocus(true);
    }
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    CEF_REQUIRE_UI_THREAD();
    (void)transition_type;
    if (frame && frame->IsMain()) {
      ApplyTransparentCanvasIfNeeded(browser);
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    CEF_REQUIRE_UI_THREAD();
    (void)httpStatusCode;
    if (frame && frame->IsMain()) {
      ApplyTransparentCanvasIfNeeded(browser);
    }
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    CEF_REQUIRE_UI_THREAD();
    std::string urlStr = target_url.ToString();
    if (!urlStr.empty()) {
      NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
      NSURL *url = [NSURL URLWithString:nsUrl];
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
    }
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    bool stillAttachedToWindow = false;
    if (browser && browser->GetHost()) {
      NSView *cefView =
          CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      if (cefView && cefView.superview) {
        [cefView removeFromSuperview];
      }
      stillAttachedToWindow = (cefView && cefView.window != nil);
    }
    if (is_popout_) {
      NSView *strongHost = host_view_;
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *win = strongHost.window;
        if (win) {
          [[SXExtensionManager sharedManager] closePopoutWindow:win];
        }
      });
    }
    // Returning false once detached lets CEF destroy the browser and invoke OnBeforeClose
    // cleanly without touching any host NSWindow.
    return stillAttachedToWindow;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
    browser_ = nullptr;
    host_view_ = nil;
  }

  void ClosePopupBrowser() {
    if (!CefCurrentlyOn(TID_UI)) {
      CefRefPtr<SXExtensionPopupClient> selfRef(this);
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                              &SXExtensionPopupClient::ClosePopupBrowser, selfRef)));
      return;
    }
    if (browser_ && browser_->GetHost()) {
      NSView *cefView =
          CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
      if (cefView && cefView.superview) {
        [cefView removeFromSuperview];
      }
      browser_->GetHost()->CloseBrowser(true);
    }
  }

  void NotifyWindowAttached() {
    if (!CefCurrentlyOn(TID_UI)) {
      CefRefPtr<SXExtensionPopupClient> selfRef(this);
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                              &SXExtensionPopupClient::NotifyWindowAttached, selfRef)));
      return;
    }
    if (browser_ && browser_->GetHost()) {
      NSView *strongHost = host_view_;
      browser_->GetHost()->NotifyScreenInfoChanged();
      FocusHostView(strongHost);
      browser_->GetHost()->SetFocus(true);
    }
  }

  void NotifyBoundsChanged() {
    if (!CefCurrentlyOn(TID_UI)) {
      CefRefPtr<SXExtensionPopupClient> selfRef(this);
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                              &SXExtensionPopupClient::NotifyBoundsChanged, selfRef)));
      return;
    }
    if (browser_ && browser_->GetHost()) {
      browser_->GetHost()->NotifyScreenInfoChanged();
    }
  }

 private:
  __weak NSView *host_view_ = nil;
  NSString *extension_id_ = @"";
  double initial_width_ = 380.0;
  double initial_height_ = 520.0;
  bool is_popout_ = false;
  bool has_painted_content_ = false;
  bool has_notified_content_ready_ = false;
  double last_width_ = 0.0;
  double last_height_ = 0.0;
  double prev_width_ = 0.0;
  double prev_height_ = 0.0;
  CFAbsoluteTime last_resize_time_ = 0.0;
  int resize_count_ = 0;
  CefRefPtr<CefBrowser> browser_;
  IMPLEMENT_REFCOUNTING(SXExtensionPopupClient);
};

@interface SXExtensionPopupView : NSView {
 @public
  CefRefPtr<SXExtensionPopupClient> _popupClient;
}
@property (nonatomic, copy) NSString *extensionID;
@end

@implementation SXExtensionPopupView

- (BOOL)isFlipped {
  return NO;
}

- (void)layout {
  [super layout];
  NSRect b = self.bounds;
  for (NSView *sub in self.subviews) {
    if (!NSEqualRects(sub.frame, b)) {
      sub.frame = b;
    }
  }
}

- (void)setFrameSize:(NSSize)newSize {
  NSSize oldSize = self.frame.size;
  [super setFrameSize:newSize];
  NSRect b = NSMakeRect(0, 0, newSize.width, newSize.height);
  for (NSView *sub in self.subviews) {
    if (!NSEqualRects(sub.frame, b)) {
      sub.frame = b;
    }
  }
  if (_popupClient && !NSEqualSizes(oldSize, newSize)) {
    _popupClient->NotifyBoundsChanged();
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    NSRect b = self.bounds;
    for (NSView *sub in self.subviews) {
      sub.frame = b;
    }
    if (_popupClient) {
      _popupClient->NotifyWindowAttached();
    }
  }
}

- (void)closeEmbeddedBrowser {
  if (_popupClient) {
    _popupClient->ClosePopupBrowser();
    _popupClient = nullptr;
  }
}

- (void)dealloc {
  [self closeEmbeddedBrowser];
}

@end

#pragma mark - Genuine Chromium Live Extension Loader (chrome://extensions + CefDialogHandler)

/// Loads unpacked MV3 extensions & uninstalls extensions LIVE inside the running
/// Chromium 156 ExtensionSystem (genuine `chrome-extension://<id>/` origin + real MV3
/// background service worker + real `chrome.storage`), with zero browser restart and
/// zero fake scheme workarounds.
///
/// Uses a single hidden 2x2 `chrome://extensions/` admin browser and intercepts its
/// `chrome.developerPrivate.loadUnpacked()` folder dialog via `CefDialogHandler::OnFileDialog`
/// so no native macOS open panel ever appears.
class SXLiveExtensionLoader : public CefClient,
                              public CefDialogHandler,
                              public CefDisplayHandler,
                              public CefLoadHandler,
                              public CefLifeSpanHandler {
 public:
  using ResultCallback = std::function<void(bool success, const std::string& loadedId)>;

  enum class Op { kLoadUnpacked, kUninstall, kSetEnabled, kSetIncognitoAccess, kReload };

  struct Task {
    int reqId = 0;
    Op op = Op::kLoadUnpacked;
    std::string arg;
    bool boolVal = false;
    ResultCallback callback;
  };

  SXLiveExtensionLoader() = default;

  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void LoadUnpacked(const std::string& dirPath, ResultCallback cb) {
    Enqueue(Op::kLoadUnpacked, dirPath, false, std::move(cb));
  }

  void Uninstall(const std::string& extId, ResultCallback cb) {
    Enqueue(Op::kUninstall, extId, false, std::move(cb));
  }

  void SetEnabled(const std::string& extId, bool enabled, ResultCallback cb) {
    Enqueue(Op::kSetEnabled, extId, enabled, std::move(cb));
  }

  void SetIncognitoAccess(const std::string& extId, bool allowed, ResultCallback cb) {
    Enqueue(Op::kSetIncognitoAccess, extId, allowed, std::move(cb));
  }

  void Reload(const std::string& extId, ResultCallback cb) {
    Enqueue(Op::kReload, extId, false, std::move(cb));
  }

  bool HasOpenBrowsers() const {
    return !open_browsers_.empty() || browser_ != nullptr;
  }

  void Shutdown() {
    CEF_REQUIRE_UI_THREAD();
    shutting_down_ = true;
    if (active_task_) {
      ResultCallback cb = std::move(active_task_->callback);
      active_task_.reset();
      if (cb) cb(false, "");
    }
    while (!queue_.empty()) {
      ResultCallback cb = std::move(queue_.front().callback);
      queue_.pop_front();
      if (cb) cb(false, "");
    }
    auto copy = open_browsers_;
    for (auto& b : copy) {
      if (b && b->GetHost()) {
        b->GetHost()->CloseBrowser(true);
      }
    }
    if (browser_ && browser_->GetHost()) {
      browser_->GetHost()->CloseBrowser(true);
    }
    ready_ = false;
    creating_ = false;
    EndCreationGuard();
  }

  bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                    FileDialogMode mode,
                    const CefString& title,
                    const CefString& default_file_path,
                    const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions,
                    const std::vector<CefString>& accept_descriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!callback) return true;
    if (!pending_dialog_dir_.empty()) {
      std::string dir = pending_dialog_dir_;
      pending_dialog_dir_.clear();
      if (getenv("SAFARIUM_CEF_DEBUG")) {
        fprintf(stderr, "[ExtLoader] OnFileDialog intercepted mode=%d -> %s\n",
                (int)mode, dir.c_str());
        fflush(stderr);
      }
      std::vector<CefString> paths;
      paths.emplace_back(dir);
      callback->Continue(paths);
      return true;
    }
    callback->Cancel();
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
    if (!browser) return;
    int bid = browser->GetIdentifier();
    open_browsers_.push_back(browser);

    // Keep ANY Chrome-style window owned by the extension loader permanently invisible
    // and completely absent from the Window menu, Mission Control, Exposé, and Cmd+`.
    if (browser->GetHost()) {
      NSView *v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      if (v && v.window) {
        NSWindow *w = v.window;
        SXLockWindowPermanentlyHidden(w);
        dispatch_async(dispatch_get_main_queue(), ^{
          SXLockWindowPermanentlyHidden(w);
        });
      }
    }
    EndCreationGuard();

    if (shutting_down_) {
      if (browser->GetHost()) browser->GetHost()->CloseBrowser(true);
      return;
    }

    if (admin_browser_id_ < 0) {
      admin_browser_id_ = bid;
      browser_ = browser;
      creating_ = false;
      if (getenv("SAFARIUM_CEF_DEBUG")) {
        fprintf(stderr, "[ExtLoader] OnAfterCreated admin id=%d\n", bid);
        fflush(stderr);
      }
    } else {
      // Extra tab spawned inside the hidden admin window (e.g. an extension's onInstalled
      // welcome page like bitwarden.com/browser-start/) -> close immediately so zero zombie
      // hidden tabs accumulate or delay shutdown.
      if (getenv("SAFARIUM_CEF_DEBUG")) {
        fprintf(stderr, "[ExtLoader] Closing extra onInstalled tab id=%d\n", bid);
        fflush(stderr);
      }
      if (browser->GetHost()) {
        browser->GetHost()->CloseBrowser(true);
      }
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    CEF_REQUIRE_UI_THREAD();
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader] OnLoadError code=%d text=%s url=%s\n",
              (int)errorCode, errorText.ToString().c_str(), failedUrl.ToString().c_str());
      fflush(stderr);
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    CEF_REQUIRE_UI_THREAD();
    if (!frame || !frame->IsMain()) return;
    std::string url = frame->GetURL().ToString();
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader] OnLoadEnd url=%s status=%d\n", url.c_str(), httpStatusCode);
      fflush(stderr);
    }
    if (url.rfind("chrome://extensions", 0) == 0) {
      ready_ = true;
      DrainQueue();
    }
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    CEF_REQUIRE_UI_THREAD();
    std::string msg = message.ToString();
    const std::string prefix = "__SX_LIVE_EXT__:";
    if (msg.rfind(prefix, 0) == 0) {
      std::string jsonStr = msg.substr(prefix.size());
      HandleResultJSON(jsonStr);
      return true;
    }
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader console %d] %s (%s:%d)\n",
              (int)level, msg.c_str(), source.ToString().c_str(), line);
      fflush(stderr);
    }
    return false;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    // Allow Chrome-style hidden admin window to close itself cleanly on shutdown.
    return false;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
    if (!browser) return;
    int bid = browser->GetIdentifier();
    open_browsers_.erase(
        std::remove_if(open_browsers_.begin(), open_browsers_.end(),
                       [bid](const CefRefPtr<CefBrowser>& b) {
                         return !b || b->GetIdentifier() == bid;
                       }),
        open_browsers_.end());
    if (bid == admin_browser_id_) {
      admin_browser_id_ = -1;
      browser_ = nullptr;
      ready_ = false;
      creating_ = false;
    }
  }

 private:
  void Enqueue(Op op, const std::string& arg, bool boolVal, ResultCallback cb) {
    if (!CefCurrentlyOn(TID_UI)) {
      CefRefPtr<SXLiveExtensionLoader> selfRef(this);
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                              &SXLiveExtensionLoader::Enqueue, selfRef, op, arg, boolVal,
                              std::move(cb))));
      return;
    }
    if (shutting_down_) {
      if (cb) cb(false, "");
      return;
    }
    Task t;
    t.reqId = ++next_req_id_;
    t.op = op;
    t.arg = arg;
    t.boolVal = boolVal;
    t.callback = std::move(cb);
    ++idle_generation_;
    queue_.push_back(std::move(t));
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader] Enqueue op=%d arg=%s\n", (int)op, arg.c_str());
      fflush(stderr);
    }
    EnsureBrowserCreated();
    DrainQueue();
  }

  void EndCreationGuard() {
    if (creation_guard_active_) {
      creation_guard_active_ = false;
      SXEndHiddenChromeWindowCreation();
    }
  }

  void ScheduleIdleClose() {
    CEF_REQUIRE_UI_THREAD();
    if (shutting_down_ || active_task_ || !queue_.empty() || !browser_) return;
    int gen = ++idle_generation_;
    CefRefPtr<SXLiveExtensionLoader> selfRef(this);
    CefPostDelayedTask(
        TID_UI,
        CefCreateClosureTask(base::BindOnce(&SXLiveExtensionLoader::CloseIfIdle, selfRef, gen)),
        2000);
  }

  void CloseIfIdle(int gen) {
    CEF_REQUIRE_UI_THREAD();
    if (shutting_down_ || gen != idle_generation_ || active_task_ || !queue_.empty()) return;
    if (browser_ && browser_->GetHost()) {
      if (getenv("SAFARIUM_CEF_DEBUG")) {
        fprintf(stderr, "[ExtLoader] Closing idle hidden admin browser id=%d\n", admin_browser_id_);
        fflush(stderr);
      }
      browser_->GetHost()->CloseBrowser(true);
    }
  }

  void EnsureBrowserCreated() {
    CEF_REQUIRE_UI_THREAD();
    if (browser_ || creating_ || shutting_down_) return;
    creating_ = true;

    // Enable developer mode preference in Chromium's profile so developerPrivate.loadUnpacked succeeds.
    CefRefPtr<CefRequestContext> ctx = CefRequestContext::GetGlobalContext();
    if (ctx) {
      CefRefPtr<CefValue> v = CefValue::Create();
      v->SetBool(true);
      CefString prefErr;
      ctx->SetPreference("extensions.ui.developer_mode", v, prefErr);
    }

    // Create a hidden offscreen Chrome-style browser (parent_view == nullptr so CEF
    // selects CEF_RUNTIME_STYLE_CHROME, enabling chrome://extensions/ and developerPrivate).
    // Guard creation with the NSWindow stealth blocker so zero Chromium frames ever reach screen.
    if (!creation_guard_active_) {
      creation_guard_active_ = true;
      SXBeginHiddenChromeWindowCreation();
      CefRefPtr<SXLiveExtensionLoader> selfRef(this);
      CefPostDelayedTask(
          TID_UI,
          CefCreateClosureTask(base::BindOnce(&SXLiveExtensionLoader::EndCreationGuard, selfRef)),
          5000);
    }
    CefWindowInfo windowInfo;
    windowInfo.parent_view = nullptr;
    windowInfo.hidden = true;
    windowInfo.bounds = CefRect(-30000, -30000, 100, 100);
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(windowInfo, this, CefString("chrome://extensions/"),
                                  settings, nullptr, nullptr);
  }

  void DrainQueue() {
    CEF_REQUIRE_UI_THREAD();
    if (!ready_ || !browser_ || !browser_->GetMainFrame() || active_task_ || queue_.empty()) {
      return;
    }
    active_task_ = std::make_unique<Task>(std::move(queue_.front()));
    queue_.pop_front();

    int reqId = active_task_->reqId;
    std::string js;
    if (active_task_->op == Op::kLoadUnpacked) {
      pending_dialog_dir_ = active_task_->arg;
      js = "(async () => {"
           "  const reqId = " + std::to_string(reqId) + ";"
           "  try { await chrome.developerPrivate.updateProfileConfiguration({ inDeveloperMode: true }); } catch (_) {}"
           "  try {"
           "    const err = await chrome.developerPrivate.loadUnpacked({ failQuietly: true, populateError: true });"
           "    const list = await chrome.developerPrivate.getExtensionsInfo({ includeDisabled: true });"
           "    const items = (list || []).map(x => ({ id: x.id || '', path: x.path || '' }));"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'load', ok: !err, err: err || null, items }));"
           "  } catch (e) {"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'load', ok: false, err: String(e), items: [] }));"
           "  }"
           "})();";
    } else if (active_task_->op == Op::kUninstall) {
      std::string extId = active_task_->arg;
      js = "(async () => {"
           "  const reqId = " + std::to_string(reqId) + ";"
           "  try {"
           "    await chrome.management.uninstall('" + extId + "', { showConfirmDialog: false });"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'uninstall', ok: true, id: '" + extId + "' }));"
           "  } catch (e) {"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'uninstall', ok: false, err: String(e) }));"
           "  }"
           "})();";
    } else if (active_task_->op == Op::kSetEnabled) {
      std::string extId = active_task_->arg;
      std::string flag = active_task_->boolVal ? "true" : "false";
      js = "(async () => {"
           "  const reqId = " + std::to_string(reqId) + ";"
           "  try {"
           "    await chrome.management.setEnabled('" + extId + "', " + flag + ");"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'setEnabled', ok: true, id: '" + extId + "' }));"
           "  } catch (e) {"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'setEnabled', ok: false, err: String(e) }));"
           "  }"
           "})();";
    } else if (active_task_->op == Op::kSetIncognitoAccess) {
      std::string extId = active_task_->arg;
      std::string flag = active_task_->boolVal ? "true" : "false";
      js = "(async () => {"
           "  const reqId = " + std::to_string(reqId) + ";"
           "  try {"
           "    await chrome.developerPrivate.updateExtensionConfiguration({ extensionId: '" + extId + "', incognitoAccess: " + flag + " });"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'setIncognito', ok: true, id: '" + extId + "' }));"
           "  } catch (e) {"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'setIncognito', ok: false, err: String(e) }));"
           "  }"
           "})();";
    } else if (active_task_->op == Op::kReload) {
      std::string extId = active_task_->arg;
      js = "(async () => {"
           "  const reqId = " + std::to_string(reqId) + ";"
           "  try {"
           "    await chrome.developerPrivate.reload('" + extId + "', { failQuietly: true });"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'reload', ok: true, id: '" + extId + "' }));"
           "  } catch (e) {"
           "    console.log('__SX_LIVE_EXT__:' + JSON.stringify({ reqId, op: 'reload', ok: false, err: String(e) }));"
           "  }"
           "})();";
    }
    browser_->GetMainFrame()->ExecuteJavaScript(CefString(js), CefString("chrome://extensions/"), 0);

    // Safety timeout (8s) so no install/uninstall can ever stall indefinitely.
    CefRefPtr<SXLiveExtensionLoader> selfRef(this);
    CefPostDelayedTask(
        TID_UI,
        CefCreateClosureTask(base::BindOnce(&SXLiveExtensionLoader::TimeoutRequest, selfRef, reqId)),
        8000);
  }

  void TimeoutRequest(int reqId) {
    CEF_REQUIRE_UI_THREAD();
    if (!active_task_ || active_task_->reqId != reqId) return;
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader] Request %d timed out\n", reqId);
      fflush(stderr);
    }
    pending_dialog_dir_.clear();
    ResultCallback cb = std::move(active_task_->callback);
    active_task_.reset();
    if (cb) cb(false, "");
    DrainQueue();
    ScheduleIdleClose();
  }

  void HandleResultJSON(const std::string& jsonStr) {
    CEF_REQUIRE_UI_THREAD();
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[ExtLoader] Result: %s\n", jsonStr.c_str());
      fflush(stderr);
    }
    NSData *data = [NSData dataWithBytes:jsonStr.data() length:jsonStr.size()];
    NSDictionary *obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    int reqId = [obj[@"reqId"] intValue];
    if (!active_task_ || active_task_->reqId != reqId) return;

    bool ok = [obj[@"ok"] boolValue];
    std::string matchedId;
    if (active_task_->op == Op::kLoadUnpacked && ok) {
      NSString *targetDir = [[NSString stringWithUTF8String:active_task_->arg.c_str()]
          stringByStandardizingPath];
      NSArray *items = obj[@"items"];
      if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *it in items) {
          if (![it isKindOfClass:[NSDictionary class]]) continue;
          NSString *p = [it[@"path"] isKindOfClass:[NSString class]]
                            ? [(NSString *)it[@"path"] stringByStandardizingPath]
                            : @"";
          NSString *eid = [it[@"id"] isKindOfClass:[NSString class]] ? it[@"id"] : @"";
          if (eid.length == 32 && [p isEqualToString:targetDir]) {
            matchedId = eid.UTF8String;
            break;
          }
        }
      }
    } else if (ok) {
      matchedId = active_task_->arg;
    }

    pending_dialog_dir_.clear();
    ResultCallback cb = std::move(active_task_->callback);
    active_task_.reset();
    if (cb) cb(ok && !matchedId.empty(), matchedId);
    DrainQueue();
    ScheduleIdleClose();
  }

  int admin_browser_id_ = -1;
  CefRefPtr<CefBrowser> browser_;
  std::vector<CefRefPtr<CefBrowser>> open_browsers_;
  bool creating_ = false;
  bool creation_guard_active_ = false;
  bool ready_ = false;
  bool shutting_down_ = false;
  int next_req_id_ = 0;
  int idle_generation_ = 0;
  std::string pending_dialog_dir_;
  std::unique_ptr<Task> active_task_;
  std::deque<Task> queue_;
  IMPLEMENT_REFCOUNTING(SXLiveExtensionLoader);
};

#pragma mark - SXExtensionManager

struct SXLiveBadgeState {
  bool hasGlobalText = false;
  std::string globalText;
  std::string globalColorSpec;
  bool hasLatestWebText = false;
  std::string latestWebText;
  std::string latestWebColorSpec;
  std::unordered_map<int, std::string> tabText;
  std::unordered_map<int, std::string> tabColorSpec;
  std::unordered_map<std::string, std::string> urlText;
  std::unordered_map<std::string, std::string> urlColorSpec;
  std::unordered_map<std::string, std::string> hostText;
  std::unordered_map<std::string, std::string> hostColorSpec;
};

static BOOL SXExtractNormalizedBadgeURL(NSURL * _Nullable url,
                                        std::string *outNormURL,
                                        std::string *outHost) {
  if (!url) return NO;
  NSString *scheme = url.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
    return NO;
  }
  NSString *host = url.host.lowercaseString;
  if (host.length == 0) return NO;
  NSString *path = url.path ?: @"";
  while (path.length > 1 && [path hasSuffix:@"/"]) {
    path = [path substringToIndex:path.length - 1];
  }
  NSString *norm = [NSString stringWithFormat:@"%@://%@%@", scheme, host, path];
  if (outNormURL) *outNormURL = norm.UTF8String;
  if (outHost) *outHost = host.UTF8String;
  return YES;
}

static NSArray<SXExtensionContextMenuItem *> *SXBuildContextMenuTree(
    NSArray<NSDictionary *> *list,
    NSDictionary<NSString *, NSArray<NSDictionary *> *> *childrenByParent,
    int depth) {
  if (depth > 5 || list.count == 0) return @[];
  NSMutableArray<SXExtensionContextMenuItem *> *out = [NSMutableArray arrayWithCapacity:list.count];
  for (NSDictionary *d in list) {
    NSString *iid = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : [NSString stringWithFormat:@"%@", d[@"id"] ?: @""];
    NSString *pid = ([d[@"parentId"] isKindOfClass:[NSString class]] && [(NSString *)d[@"parentId"] length] > 0) ? d[@"parentId"] : nil;
    NSString *typeStr = [d[@"type"] isKindOfClass:[NSString class]] ? [d[@"type"] lowercaseString] : @"normal";
    BOOL isSep = [typeStr isEqualToString:@"separator"];
    NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : @"";
    // Strip single Chrome mnemonic '&' if present (e.g. "&Copy" -> "Copy")
    title = [title stringByReplacingOccurrencesOfString:@"&&" withString:@"\u0001"];
    title = [title stringByReplacingOccurrencesOfString:@"&" withString:@""];
    title = [title stringByReplacingOccurrencesOfString:@"\u0001" withString:@"&"];
    BOOL enabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    BOOL checked = d[@"checked"] ? [d[@"checked"] boolValue] : NO;
    NSArray<NSDictionary *> *kidsRaw = childrenByParent[iid];
    NSArray<SXExtensionContextMenuItem *> *kids =
        (kidsRaw.count > 0) ? SXBuildContextMenuTree(kidsRaw, childrenByParent, depth + 1) : @[];
    if (!isSep && title.length == 0 && kids.count == 0) continue;
    [out addObject:[[SXExtensionContextMenuItem alloc] initWithItemID:iid
                                                             parentID:pid
                                                                title:title
                                                            separator:isSep
                                                              enabled:enabled
                                                              checked:checked
                                                             children:kids]];
  }
  return out;
}

@interface SXExtensionManager () <NSWindowDelegate> {
  CefRefPtr<SXLiveExtensionLoader> _liveLoader;
  std::vector<CefRefPtr<CefBrowser>> _liveBrowsers;

  // In-process loopback bridge for MV3 Service Worker badge & contextMenus telemetry/dispatch
  int _bridgeListenFD;
  uint16_t _bridgePort;
  std::string _bridgeToken;
  std::unordered_map<std::string, std::string> _bridgeDirByKey;   // per-extension key -> canonical dir
  std::unordered_map<std::string, bool> _bridgeTabAccessByKey;     // per-extension key -> manifest grants tab access
  std::atomic<bool> _bridgeRunning;
  std::thread _bridgeAcceptThread;
  std::mutex _bridgeMutex;
  std::condition_variable _bridgeCV;
  std::unordered_map<std::string, SXLiveBadgeState> _liveBadges;
  std::unordered_map<std::string, std::deque<std::string>> _pendingMenuClicks;
  std::unordered_map<std::string, int> _realTabIdByNormURL;
  std::unordered_map<std::string, int> _realTabIdByHost;
  int _lastRealWebTabId;
  uint64_t _activeTabSeq;
  int _activeTabId;
  std::string _activeTabURL;
  std::string _activeTabTitle;
  std::atomic<bool> _badgeNotifyPending;
}

@property (nonatomic, copy) NSString *profileRootDir;
@property (nonatomic, copy) NSString *extensionsRootDir;
@property (nonatomic, copy) NSString *registryFilePath;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *registryEntries;
@property (nonatomic, strong) NSMutableSet<NSString *> *nativelyLoadedIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightStoreIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SXExtensionPopupView *> *activePopups;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *popoutWindows;
/// URL each popout was opened with (its extension id is the host); lets the service-worker bridge list, focus and
/// close popouts, which chrome.tabs / chrome.windows cannot see.
@property (nonatomic, strong) NSMapTable<NSWindow *, NSString *> *popoutURLs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<SXExtensionContextMenuItem *> *> *liveContextMenus;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *liveBadgeColorCache;

@end



/// True unless the registry knows `extId` under a *different* directory than the caller's (fail-open when the id is not
/// registered yet, so a freshly installed extension is never locked out).
static BOOL SXBridgeExtIdBelongsToCaller(SXExtensionManager *mgr, NSString *extId, NSString *callerDir) {
  if (extId.length == 0 || callerDir.length == 0) return YES;
  NSString *wantId = [extId lowercaseString];
  __block BOOL mismatch = NO;
  void (^check)(void) = ^{
    for (NSDictionary *e in [mgr.registryEntries copy]) {
      NSString *eid = [e[@"id"] isKindOfClass:[NSString class]] ? [(NSString *)e[@"id"] lowercaseString] : nil;
      NSString *ep = [e[@"path"] isKindOfClass:[NSString class]] ? e[@"path"] : nil;
      if (eid && ep && [eid isEqualToString:wantId]) {
        NSString *canon = [[ep stringByStandardizingPath] stringByResolvingSymlinksInPath];
        if (![canon isEqualToString:callerDir]) mismatch = YES;
      }
    }
  };
  if ([NSThread isMainThread]) check(); else dispatch_sync(dispatch_get_main_queue(), check);
  return !mismatch;
}

@implementation SXExtensionManager

+ (instancetype)sharedManager {
  static SXExtensionManager *shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shared = [[SXExtensionManager alloc] initPrivate];
  });
  return shared;
}

- (instancetype)initPrivate {
  self = [super init];
  if (self) {
    _registryEntries = [NSMutableArray array];
    _nativelyLoadedIDs = [NSMutableSet set];
    _inFlightStoreIDs = [NSMutableSet set];
    _activePopups = [NSMutableDictionary dictionary];
    _popoutWindows = [NSMutableArray array];
    _popoutURLs = [NSMapTable weakToStrongObjectsMapTable];
    _liveContextMenus = [NSMutableDictionary dictionary];
    _liveBadgeColorCache = [NSMutableDictionary dictionary];
    _liveLoader = new SXLiveExtensionLoader();
    _bridgeListenFD = -1;
    _bridgePort = 0;
    _bridgeRunning.store(false);
    _lastRealWebTabId = -1;
    _activeTabSeq = 0;
    _activeTabId = 1;
    _badgeNotifyPending.store(false);
  }
  return self;
}

- (NSString *)loadOrCreatePersistedBridgeToken {
  if (self.extensionsRootDir.length > 0) {
    NSString *tokPath = [self.extensionsRootDir stringByAppendingPathComponent:@".bridge_token"];
    NSString *existing = [NSString stringWithContentsOfFile:tokPath encoding:NSUTF8StringEncoding error:nil];
    existing = [existing stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing.length >= 16) {
      return existing;
    }
    NSString *fresh = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    [fresh writeToFile:tokPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return fresh;
  }
  return [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

- (void)startBridgeServerIfNeeded {
  if (_bridgeRunning.load() && _bridgePort != 0) {
    return;
  }

  int fd = -1;
  uint16_t boundPort = 0;
  // Deterministic loopback port range so cached MV3 Service Worker scripts remain valid across restarts
  for (uint16_t candidate = 47931; candidate <= 47940; ++candidate) {
    int tryFD = socket(AF_INET, SOCK_STREAM, 0);
    if (tryFD < 0) continue;
    int one = 1;
    setsockopt(tryFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(tryFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(candidate);
    if (bind(tryFD, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(tryFD, 32) == 0) {
      fd = tryFD;
      boundPort = candidate;
      break;
    }
    close(tryFD);
  }

  if (fd < 0) {
    // Fallback to ephemeral port if all 10 deterministic ports are busy
    int tryFD = socket(AF_INET, SOCK_STREAM, 0);
    if (tryFD < 0) return;
    int one = 1;
    setsockopt(tryFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(tryFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(tryFD, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(tryFD, 32) != 0) {
      close(tryFD);
      return;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(tryFD, (struct sockaddr *)&addr, &len) != 0) {
      close(tryFD);
      return;
    }
    fd = tryFD;
    boundPort = ntohs(addr.sin_port);
  }

  _bridgeListenFD = fd;
  _bridgePort = boundPort;
  NSString *tok = [self loadOrCreatePersistedBridgeToken];
  _bridgeToken = tok.UTF8String;
  _bridgeRunning.store(true);
  NSLog(@"[Safarium] Extension SW bridge listening on port %u", (unsigned)_bridgePort);

  SXExtensionManager *mgr = self;
  _bridgeAcceptThread = std::thread([mgr, fd]() {
    while (mgr->_bridgeRunning.load()) {
      struct sockaddr_in clientAddr;
      socklen_t clientLen = sizeof(clientAddr);
      int cfd = accept(fd, (struct sockaddr *)&clientAddr, &clientLen);
      if (cfd < 0) {
        if (!mgr->_bridgeRunning.load()) break;
        continue;
      }
      int nosig = 1;
      setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
      std::thread([mgr, cfd]() {
        @autoreleasepool {
          [mgr handleBridgeClientFD:cfd];
        }
        close(cfd);
      }).detach();
    }
  });
}

- (void)stopBridgeServer {
  if (!_bridgeRunning.exchange(false)) {
    return;
  }
  _bridgeCV.notify_all();
  uint16_t port = _bridgePort;
  if (port != 0) {
    int wake = socket(AF_INET, SOCK_STREAM, 0);
    if (wake >= 0) {
      struct sockaddr_in addr;
      memset(&addr, 0, sizeof(addr));
      addr.sin_family = AF_INET;
      addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      addr.sin_port = htons(port);
      connect(wake, (struct sockaddr *)&addr, sizeof(addr));
      close(wake);
    }
  }
  if (_bridgeListenFD >= 0) {
    close(_bridgeListenFD);
    _bridgeListenFD = -1;
  }
  if (_bridgeAcceptThread.joinable()) {
    _bridgeAcceptThread.join();
  }
  _bridgePort = 0;
}

static void SXSendHTTPResponse(int fd, int status, const char *statusText, const std::string &body) {
  std::string hdr = "HTTP/1.1 " + std::to_string(status) + " " + statusText + "\r\n"
                    "Access-Control-Allow-Origin: *\r\n"
                    "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                    "Access-Control-Allow-Headers: content-type\r\n"
                    "Access-Control-Allow-Private-Network: true\r\n"
                    "Content-Type: application/json\r\n"
                    "Cache-Control: no-store\r\n"
                    "Connection: close\r\n"
                    "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n";
  std::string full = hdr + body;
  const char *p = full.data();
  size_t rem = full.size();
  while (rem > 0) {
    ssize_t n = send(fd, p, rem, 0);
    if (n <= 0) break;
    p += n;
    rem -= (size_t)n;
  }
}

static std::string SXQueryParam(const std::string &query, const std::string &key) {
  std::string needle = key + "=";
  size_t pos = 0;
  while (pos < query.size()) {
    size_t amp = query.find('&', pos);
    std::string pair = (amp == std::string::npos) ? query.substr(pos) : query.substr(pos, amp - pos);
    if (pair.rfind(needle, 0) == 0) {
      return pair.substr(needle.size());
    }
    if (amp == std::string::npos) break;
    pos = amp + 1;
  }
  return "";
}

- (void)handleBridgeClientFD:(int)cfd {
  struct timeval tv;
  tv.tv_sec = 2;
  tv.tv_usec = 0;
  setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  std::string req;
  char buf[4096];
  size_t headerEnd = std::string::npos;
  size_t contentLength = 0;

  while (req.size() < 512 * 1024) {
    ssize_t n = recv(cfd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    req.append(buf, (size_t)n);
    if (headerEnd == std::string::npos) {
      headerEnd = req.find("\r\n\r\n");
      if (headerEnd != std::string::npos) {
        std::string hdrs = req.substr(0, headerEnd);
        std::string lowerHdrs = hdrs;
        for (char &c : lowerHdrs) {
          if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        }
        size_t clPos = lowerHdrs.find("content-length:");
        if (clPos != std::string::npos) {
          size_t lineEnd = lowerHdrs.find("\r\n", clPos);
          std::string val = lowerHdrs.substr(clPos + 15, (lineEnd == std::string::npos ? lowerHdrs.size() : lineEnd) - (clPos + 15));
          contentLength = (size_t)strtoull(val.c_str(), nullptr, 10);
          if (contentLength > 256 * 1024) contentLength = 256 * 1024;
        }
      }
    }
    if (headerEnd != std::string::npos && req.size() >= headerEnd + 4 + contentLength) {
      break;
    }
  }
  if (headerEnd == std::string::npos) return;

  size_t firstLineEnd = req.find("\r\n");
  if (firstLineEnd == std::string::npos) return;
  std::string reqLine = req.substr(0, firstLineEnd);
  size_t sp1 = reqLine.find(' ');
  size_t sp2 = (sp1 == std::string::npos) ? std::string::npos : reqLine.find(' ', sp1 + 1);
  if (sp1 == std::string::npos || sp2 == std::string::npos) return;

  std::string method = reqLine.substr(0, sp1);
  std::string target = reqLine.substr(sp1 + 1, sp2 - sp1 - 1);
  if (method == "OPTIONS") {
    SXSendHTTPResponse(cfd, 204, "No Content", "");
    return;
  }

  std::string path = target;
  std::string query;
  size_t qpos = target.find('?');
  if (qpos != std::string::npos) {
    path = target.substr(0, qpos);
    query = target.substr(qpos + 1);
  }
  // Per-extension credentials: token must be HMAC(globalToken, key) and the key must belong to a directory we injected.
  const std::string bridgeKey = SXQueryParam(query, "key");
  bool bridgeTabAccess = false;
  std::string bridgeDir;
  {
    std::lock_guard<std::mutex> lock(_bridgeMutex);
    auto it = _bridgeDirByKey.find(bridgeKey);
    if (it != _bridgeDirByKey.end()) {
      bridgeDir = it->second;
      auto ta = _bridgeTabAccessByKey.find(bridgeKey);
      bridgeTabAccess = (ta != _bridgeTabAccessByKey.end()) && ta->second;
    }
  }
  if (bridgeKey.empty() || bridgeDir.empty() ||
      !SXConstantTimeEquals(SXQueryParam(query, "token"), SXBridgeTokenForKey(_bridgeToken, bridgeKey))) {
    SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"forbidden\"}");
    return;
  }

  std::string body = req.substr(headerEnd + 4, contentLength);

  if (method == "POST" && path == "/badge") {
    NSData *jsonData = [NSData dataWithBytes:body.data() length:body.size()];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if ([dict isKindOfClass:[NSDictionary class]]) {
      if (!SXBridgeExtIdBelongsToCaller(self, [dict[@"extId"] isKindOfClass:[NSString class]] ? dict[@"extId"] : nil,
                                         [NSString stringWithUTF8String:bridgeDir.c_str()])) {
        SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"extId does not belong to caller\"}");
        return;
      }
      [self ingestBridgeBadgePayload:dict];
    }
    SXSendHTTPResponse(cfd, 200, "OK", "{\"ok\":true}");
    return;
  }

  if (method == "POST" && path == "/menus") {
    NSData *jsonData = [NSData dataWithBytes:body.data() length:body.size()];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if ([dict isKindOfClass:[NSDictionary class]]) {
      if (!SXBridgeExtIdBelongsToCaller(self, [dict[@"extId"] isKindOfClass:[NSString class]] ? dict[@"extId"] : nil,
                                         [NSString stringWithUTF8String:bridgeDir.c_str()])) {
        SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"extId does not belong to caller\"}");
        return;
      }
      [self ingestBridgeMenusPayload:dict];
    }
    SXSendHTTPResponse(cfd, 200, "OK", "{\"ok\":true}");
    return;
  }

  if (method == "POST" && path == "/open-tab") {
    NSData *jsonData = [NSData dataWithBytes:body.data() length:body.size()];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if ([dict isKindOfClass:[NSDictionary class]]) {
      NSString *urlStr = [dict[@"url"] isKindOfClass:[NSString class]] ? dict[@"url"] : nil;
      NSURL *url = urlStr.length > 0 ? [NSURL URLWithString:urlStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
    }
    SXSendHTTPResponse(cfd, 200, "OK", "{\"ok\":true}");
    return;
  }

  if (method == "POST" && path == "/real-tab") {
    NSData *jsonData = [NSData dataWithBytes:body.data() length:body.size()];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if ([dict isKindOfClass:[NSDictionary class]]) {
      NSNumber *tidNum = [dict[@"tabId"] isKindOfClass:[NSNumber class]] ? dict[@"tabId"] : nil;
      NSString *urlStr = [dict[@"url"] isKindOfClass:[NSString class]] ? dict[@"url"] : nil;
      int tid = tidNum ? [tidNum intValue] : -1;
      if (tid > 0 && urlStr.length > 0) {
        std::string normURL, host;
        NSURL *u = [NSURL URLWithString:urlStr];
        if (SXExtractNormalizedBadgeURL(u, &normURL, &host)) {
          std::lock_guard<std::mutex> lock(_bridgeMutex);
          _realTabIdByNormURL[normURL] = tid;
          _realTabIdByHost[host] = tid;
          _lastRealWebTabId = tid;
        }
      }
    }
    SXSendHTTPResponse(cfd, 200, "OK", "{\"ok\":true}");
    return;
  }

  if (method == "GET" && (path == "/active-tab" || path == "/snapshot") && !bridgeTabAccess) {
    SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"extension lacks tabs/activeTab permission\"}");
    return;
  }

  if (method == "GET" && path == "/active-tab") {
    uint64_t seq = 0;
    int tid = 1;
    std::string urlStr;
    std::string titleStr;
    {
      std::lock_guard<std::mutex> lock(_bridgeMutex);
      seq = _activeTabSeq;
      tid = _activeTabId;
      urlStr = _activeTabURL;
      titleStr = _activeTabTitle;
    }
    NSDictionary *resp = @{
      @"tabSeq" : @(seq),
      @"activeTabId" : @(tid),
      @"activeTabUrl" : [NSString stringWithUTF8String:urlStr.c_str()] ?: @"",
      @"activeTabTitle" : [NSString stringWithUTF8String:titleStr.c_str()] ?: @"",
    };
    NSData *outData = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
    std::string json = outData ? std::string((const char *)outData.bytes, outData.length) : "{}";
    SXSendHTTPResponse(cfd, 200, "OK", json);
    return;
  }

  if (method == "GET" && path == "/snapshot") {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *pngData = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      SXBrowserTab *activeTab = SXFindActiveVisibleTab();
      if (!activeTab) {
        dispatch_semaphore_signal(sem);
        return;
      }
      [activeTab captureSnapshotWithCompletion:^(NSImage * _Nullable image) {
        if (image) {
          CGImageRef cgImg = [image CGImageForProposedRect:NULL context:nil hints:nil];
          if (cgImg) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
            pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
          }
        }
        dispatch_semaphore_signal(sem);
      }];
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    if (pngData.length > 0) {
      // (No caller-chosen output path: writing a screenshot to an arbitrary /tmp location is not exposed to extensions.)
      NSDictionary *ok = @{@"ok" : @YES, @"bytes" : @(pngData.length)};
      NSData *jd = [NSJSONSerialization dataWithJSONObject:ok options:0 error:nil];
      std::string json = jd ? std::string((const char *)jd.bytes, jd.length) : "{\"ok\":true}";
      SXSendHTTPResponse(cfd, 200, "OK", json);
    } else {
      SXSendHTTPResponse(cfd, 500, "Internal Server Error", "{\"ok\":false}");
    }
    return;
  }

  // Popouts of the calling extension (chrome.tabs/windows cannot see them): list, focus, close.
  if ((method == "GET" && path == "/popouts") || (method == "POST" && path == "/popout-action")) {
    NSString *extId = nil;
    NSDictionary *dict = nil;
    if (method == "GET") {
      extId = [NSString stringWithUTF8String:SXQueryParam(query, "extId").c_str()];
    } else {
      NSData *jsonData = [NSData dataWithBytes:body.data() length:body.size()];
      dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
      if ([dict isKindOfClass:[NSDictionary class]] && [dict[@"extId"] isKindOfClass:[NSString class]]) extId = dict[@"extId"];
    }
    extId = extId.lowercaseString;
    if (extId.length == 0 ||
        !SXBridgeExtIdBelongsToCaller(self, extId, [NSString stringWithUTF8String:bridgeDir.c_str()])) {
      SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"extId does not belong to caller\"}");
      return;
    }
    NSInteger wantId = [dict[@"id"] isKindOfClass:[NSNumber class]] ? [dict[@"id"] integerValue] : -1;
    NSString *action = [dict[@"action"] isKindOfClass:[NSString class]] ? dict[@"action"] : @"";
    __block NSMutableArray *list = [NSMutableArray array];
    void (^work)(void) = ^{
      for (NSWindow *win in [self.popoutWindows copy]) {
        NSString *u = [self.popoutURLs objectForKey:win];
        if (![[NSURL URLWithString:u ?: @""].host.lowercaseString isEqualToString:extId]) continue;
        if (wantId < 0) {
          [list addObject:@{@"id" : @(win.windowNumber), @"url" : u ?: @""}];
        } else if (win.windowNumber == wantId) {
          if ([action isEqualToString:@"close"]) {
            [self closePopoutWindow:win];
          } else if ([action isEqualToString:@"focus"]) {
            [win makeKeyAndOrderFront:nil];
          }
        }
      }
    };
    if (NSThread.isMainThread) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    NSData *out = [NSJSONSerialization dataWithJSONObject:@{@"popouts" : list} options:0 error:nil];
    std::string outStr(out ? (const char *)out.bytes : "{}", out ? out.length : 2);
    SXSendHTTPResponse(cfd, 200, "OK", outStr.c_str());
    return;
  }

  if (method == "GET" && path == "/events") {
    std::string extId = SXQueryParam(query, "extId");
    for (char &c : extId) {
      if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    }
    if (extId.empty()) {
      SXSendHTTPResponse(cfd, 400, "Bad Request", "{\"error\":\"missing extId\"}");
      return;
    }
    if (!SXBridgeExtIdBelongsToCaller(self, [NSString stringWithUTF8String:extId.c_str()],
                                       [NSString stringWithUTF8String:bridgeDir.c_str()])) {
      SXSendHTTPResponse(cfd, 403, "Forbidden", "{\"error\":\"extId does not belong to caller\"}");
      return;
    }
    std::string seqStr = SXQueryParam(query, "tabSeq");
    uint64_t clientTabSeq = seqStr.empty() ? 0 : (uint64_t)strtoull(seqStr.c_str(), nullptr, 10);

    std::vector<std::string> clicks;
    uint64_t outTabSeq = 0;
    int outActiveTabId = 1;
    std::string outActiveTabURL;
    std::string outActiveTabTitle;
    bool hasTabChange = false;
    {
      std::unique_lock<std::mutex> lock(_bridgeMutex);
      auto predicate = [&]() {
        if (!_bridgeRunning.load()) return true;
        if (_activeTabSeq > clientTabSeq) return true;
        auto it = _pendingMenuClicks.find(extId);
        return it != _pendingMenuClicks.end() && !it->second.empty();
      };
      _bridgeCV.wait_for(lock, std::chrono::seconds(20), predicate);
      auto it = _pendingMenuClicks.find(extId);
      if (it != _pendingMenuClicks.end()) {
        while (!it->second.empty()) {
          clicks.push_back(std::move(it->second.front()));
          it->second.pop_front();
        }
      }
      if (_activeTabSeq > clientTabSeq) {
        hasTabChange = true;
        outTabSeq = _activeTabSeq;
        outActiveTabId = _activeTabId;
        outActiveTabURL = _activeTabURL;
        outActiveTabTitle = _activeTabTitle;
      }
    }
    if (clicks.empty() && !hasTabChange) {
      SXSendHTTPResponse(cfd, 204, "No Content", "");
      return;
    }
    NSMutableDictionary *respObj = [NSMutableDictionary dictionary];
    if (!clicks.empty()) {
      NSMutableArray *parsedClicks = [NSMutableArray arrayWithCapacity:clicks.size()];
      for (const std::string &cs : clicks) {
        NSData *cd = [NSData dataWithBytes:cs.data() length:cs.size()];
        id obj = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil];
        if (obj) [parsedClicks addObject:obj];
      }
      respObj[@"clicks"] = parsedClicks;
    }
    if (hasTabChange) {
      respObj[@"tabSeq"] = @(outTabSeq);
      respObj[@"activeTabId"] = @(outActiveTabId);
      respObj[@"activeTabUrl"] = [NSString stringWithUTF8String:outActiveTabURL.c_str()] ?: @"";
      respObj[@"activeTabTitle"] = [NSString stringWithUTF8String:outActiveTabTitle.c_str()] ?: @"";
    }
    NSData *outData = [NSJSONSerialization dataWithJSONObject:respObj options:0 error:nil];
    std::string json = outData ? std::string((const char *)outData.bytes, outData.length) : "{}";
    SXSendHTTPResponse(cfd, 200, "OK", json);
    return;
  }

  SXSendHTTPResponse(cfd, 404, "Not Found", "{\"error\":\"not_found\"}");
}

- (void)scheduleThrottledExtensionsNotify {
  if (_badgeNotifyPending.exchange(true)) {
    return;
  }
  __weak SXExtensionManager *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.045 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   SXExtensionManager *strongSelf = weakSelf;
                   if (!strongSelf) return;
                   strongSelf->_badgeNotifyPending.store(false);
                   [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
                 });
}

- (void)ingestBridgeBadgePayload:(NSDictionary *)payload {
  NSString *extId = [payload[@"extId"] isKindOfClass:[NSString class]] ? [payload[@"extId"] lowercaseString] : nil;
  if (extId.length == 0) return;

  BOOL hasTabId = [payload[@"tabId"] isKindOfClass:[NSNumber class]];
  int tabId = hasTabId ? [payload[@"tabId"] intValue] : -1;
  NSString *tabUrlStr = [payload[@"tabUrl"] isKindOfClass:[NSString class]] ? payload[@"tabUrl"] : nil;
  std::string normURL;
  std::string host;
  BOOL hasValidWebURL = NO;
  if (tabUrlStr.length > 0) {
    NSURL *u = [NSURL URLWithString:tabUrlStr];
    hasValidWebURL = SXExtractNormalizedBadgeURL(u, &normURL, &host);
  }

  BOOL hasText = payload[@"text"] != nil && payload[@"text"] != [NSNull null];
  NSString *textStr = hasText ? [NSString stringWithFormat:@"%@", payload[@"text"]] : nil;
  if ([textStr isEqualToString:@"<<declarativeNetRequestActionCount>>"]) {
    // Chromium's internal DNR placeholder sentinel; not a real visible badge count.
    return;
  }
  BOOL hasColor = payload[@"color"] != nil && payload[@"color"] != [NSNull null];
  NSString *colorKey = nil;
  if (hasColor) {
    NSData *cData = [NSJSONSerialization dataWithJSONObject:@{@"c" : payload[@"color"]} options:0 error:nil];
    if (cData) {
      colorKey = [[NSString alloc] initWithData:cData encoding:NSUTF8StringEncoding];
    }
  }

  BOOL changed = NO;
  {
    std::lock_guard<std::mutex> lock(_bridgeMutex);
    SXLiveBadgeState &st = _liveBadges[extId.UTF8String];
    if (hasText) {
      std::string t = textStr.UTF8String;
      if (hasValidWebURL) {
        if (st.urlText[normURL] != t || st.hostText[host] != t) changed = YES;
        st.urlText[normURL] = t;
        st.hostText[host] = t;
        st.hasLatestWebText = true;
        st.latestWebText = t;
      } else if (hasTabId && tabId >= 0) {
        if (st.tabText[tabId] != t) changed = YES;
        st.tabText[tabId] = t;
        st.hasLatestWebText = true;
        st.latestWebText = t;
      } else {
        if (!st.hasGlobalText || st.globalText != t) changed = YES;
        st.hasGlobalText = true;
        st.globalText = t;
      }
    }
    if (colorKey.length > 0) {
      std::string cs = colorKey.UTF8String;
      if (hasValidWebURL) {
        if (st.urlColorSpec[normURL] != cs) changed = YES;
        st.urlColorSpec[normURL] = cs;
        st.hostColorSpec[host] = cs;
        st.latestWebColorSpec = cs;
      } else if (hasTabId && tabId >= 0) {
        if (st.tabColorSpec[tabId] != cs) changed = YES;
        st.tabColorSpec[tabId] = cs;
        st.latestWebColorSpec = cs;
      } else {
        if (st.globalColorSpec != cs) changed = YES;
        st.globalColorSpec = cs;
      }
    }
  }
  if (changed && hasText) {
    NSLog(@"[Safarium] Extension badge update: %@ text='%@' url='%@' tabId=%d",
          extId, textStr ?: @"", tabUrlStr ?: @"(global)", tabId);
  }
  if (changed) {
    [self scheduleThrottledExtensionsNotify];
  }
}

- (void)ingestBridgeMenusPayload:(NSDictionary *)payload {
  NSString *extId = [payload[@"extId"] isKindOfClass:[NSString class]] ? [payload[@"extId"] lowercaseString] : nil;
  NSArray *rawItems = [payload[@"items"] isKindOfClass:[NSArray class]] ? payload[@"items"] : nil;
  if (extId.length == 0 || !rawItems) return;

  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *childrenByParent = [NSMutableDictionary dictionary];
  NSMutableArray<NSDictionary *> *roots = [NSMutableArray array];

  for (id obj in rawItems) {
    if (![obj isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *d = (NSDictionary *)obj;
    NSString *iid = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : [NSString stringWithFormat:@"%@", d[@"id"] ?: @""];
    if (!iid.length) continue;
    NSString *pid = ([d[@"parentId"] isKindOfClass:[NSString class]] && [(NSString *)d[@"parentId"] length] > 0)
                        ? d[@"parentId"]
                        : nil;
    if (pid) {
      NSMutableArray *arr = childrenByParent[pid];
      if (!arr) {
        arr = [NSMutableArray array];
        childrenByParent[pid] = arr;
      }
      [arr addObject:d];
    } else {
      [roots addObject:d];
    }
  }

  NSArray<SXExtensionContextMenuItem *> *tree = SXBuildContextMenuTree(roots, childrenByParent, 0);
  // If an extension wraps all its items under a single top-level root item (e.g. Bitwarden's "Bitwarden" root),
  // unwrap that root so our "<Extension Name> >" submenu displays its children directly like Safari!
  if (tree.count == 1 && !tree.firstObject.isSeparator && tree.firstObject.children.count > 0) {
    tree = tree.firstObject.children;
  }

  NSLog(@"[Safarium] Extension menus update: %@ count=%lu", extId, (unsigned long)tree.count);
  dispatch_async(dispatch_get_main_queue(), ^{
    self.liveContextMenus[extId] = tree;
  });
}

- (void)notifyActiveTabChanged {
  SXBrowserTab *activeTab = SXFindActiveVisibleTab();
  int nextTabId = activeTab ? [activeTab chromiumBrowserIdentifier] : 1;
  if (nextTabId <= 0) nextTabId = 1;
  NSString *urlStr = activeTab.currentURL.absoluteString ?: @"";
  NSString *titleStr = activeTab.title ?: @"";
  std::string nextURL = urlStr.UTF8String;
  std::string nextTitle = titleStr.UTF8String;
  bool changed = false;
  {
    std::lock_guard<std::mutex> lock(_bridgeMutex);
    if (nextURL != _activeTabURL || nextTabId != _activeTabId) {
      _activeTabId = nextTabId;
      _activeTabURL = std::move(nextURL);
      _activeTabTitle = std::move(nextTitle);
      _activeTabSeq += 1;
      changed = true;
    } else if (nextTitle != _activeTabTitle) {
      _activeTabTitle = std::move(nextTitle);
    }
  }
  if (changed) {
    _bridgeCV.notify_all();
  }
  [self scheduleThrottledExtensionsNotify];
}

- (NSArray<SXExtensionContextMenuItem *> *)contextMenuItemsForExtensionID:(NSString *)extensionID {
  if (!extensionID.length) return @[];
  NSArray<SXExtensionContextMenuItem *> *items = self.liveContextMenus[[extensionID lowercaseString]];
  return items ?: @[];
}

- (void)triggerContextMenuItemWithID:(NSString *)menuItemID
                      forExtensionID:(NSString *)extensionID
                             pageURL:(nullable NSURL *)pageURL {
  if (!menuItemID.length || !extensionID.length) return;
  SXBrowserTab *activeTab = SXFindActiveVisibleTab();
  NSString *urlStr = pageURL.absoluteString ?: activeTab.currentURL.absoluteString ?: @"";
  int tabId = activeTab ? [activeTab chromiumBrowserIdentifier] : -1;
  NSDictionary *evt = @{
    @"menuItemId" : menuItemID,
    @"pageUrl" : urlStr,
    @"tabId" : @(tabId),
  };
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:evt options:0 error:nil];
  if (!jsonData) return;
  std::string jsonStr((const char *)jsonData.bytes, jsonData.length);
  std::string key = [extensionID lowercaseString].UTF8String;
  {
    std::lock_guard<std::mutex> lock(_bridgeMutex);
    _pendingMenuClicks[key].push_back(std::move(jsonStr));
  }
  _bridgeCV.notify_all();
}

- (void)configureWithProfileDirectory:(NSString *)profileDirectory {
  self.profileRootDir = profileDirectory;
  self.extensionsRootDir =
      [profileDirectory stringByAppendingPathComponent:@"SafariumExtensions"];
  self.registryFilePath =
      [self.extensionsRootDir stringByAppendingPathComponent:@"registry.json"];
  [[NSFileManager defaultManager] createDirectoryAtPath:self.extensionsRootDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  [self startBridgeServerIfNeeded];
  [self loadRegistryFromDisk];
}

- (void)invalidateStaleServiceWorkerScriptCache {
  if (!self.profileRootDir.length) return;
  NSFileManager *fm = [NSFileManager defaultManager];
  // Clear ONLY Chromium's compiled Service Worker script cache & SW registration DB so modified
  // MV3 service workers reload fresh from disk. Never touches IndexedDB, Local Extension Settings,
  // Sync Extension Settings, or Preferences (extension logins/vaults stay 100% intact).
  NSArray<NSString *> *relPaths = @[
    @"Default/Service Worker/ScriptCache",
    @"Default/Service Worker/Database",
    @"Service Worker/ScriptCache",
    @"Service Worker/Database"
  ];
  for (NSString *rel in relPaths) {
    NSString *abs = [self.profileRootDir stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:abs]) {
      NSError *err = nil;
      if ([fm removeItemAtPath:abs error:&err]) {
        NSLog(@"[Safarium] Cleared stale SW cache: %@", rel);
      }
    }
  }
}

- (void)loadRegistryFromDisk {
  [self.registryEntries removeAllObjects];
  NSData *data = [NSData dataWithContentsOfFile:self.registryFilePath];
  if (data) {
    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:nil];
    if ([parsed isKindOfClass:[NSArray class]]) {
      NSFileManager *fm = [NSFileManager defaultManager];
      for (id obj in (NSArray *)parsed) {
        if (![obj isKindOfClass:[NSMutableDictionary class]]) continue;
        NSString *path = obj[@"path"];
        if (path.length > 0 &&
            [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"manifest.json"]]) {
          [self.registryEntries addObject:obj];
        }
      }
    }
  }
}

- (void)saveRegistryToDisk {
  if (!self.registryFilePath.length) return;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self.registryEntries
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:nil];
  if (data) {
    [data writeToFile:self.registryFilePath atomically:YES];
  }
}

- (NSArray<NSString *> *)startupExtensionDirectories {
  NSMutableArray<NSString *> *dirs = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL anyBridgeChanged = NO;
  for (NSDictionary *entry in self.registryEntries) {
    BOOL enabled = entry[@"enabled"] ? [entry[@"enabled"] boolValue] : YES;
    NSString *path = entry[@"path"];
    if (enabled && path.length > 0 &&
        [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"manifest.json"]]) {
      if ([self ensureServiceWorkerBridgeInDirectory:path]) {
        anyBridgeChanged = YES;
      }
      [dirs addObject:path];
      NSString *eid = entry[@"extensionID"];
      if ([eid isKindOfClass:[NSString class]] && eid.length == 32) {
        [self.nativelyLoadedIDs addObject:[eid lowercaseString]];
      }
    }
  }
  NSString *currentSig = [NSString stringWithFormat:@"V9:%u:%s", (unsigned)_bridgePort, _bridgeToken.c_str()];
  NSString *sigPath = self.extensionsRootDir.length
                          ? [self.extensionsRootDir stringByAppendingPathComponent:@".bridge_sig"]
                          : nil;
  NSString *savedSig = sigPath ? [NSString stringWithContentsOfFile:sigPath encoding:NSUTF8StringEncoding error:nil] : nil;
  if (anyBridgeChanged || ![savedSig isEqualToString:currentSig]) {
    [self invalidateStaleServiceWorkerScriptCache];
    if (sigPath) {
      [currentSig writeToFile:sigPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
  }
  return dirs;
}

- (nullable SXExtensionItem *)buildItemFromEntry:(NSDictionary *)entry {
  NSString *dir = entry[@"path"];
  if (!dir.length) return nil;
  NSString *manifestPath = [dir stringByAppendingPathComponent:@"manifest.json"];
  NSData *mdata = [NSData dataWithContentsOfFile:manifestPath];
  if (!mdata) return nil;
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]]) return nil;

  NSDictionary *action = manifest[@"action"];
  if (![action isKindOfClass:[NSDictionary class]]) action = manifest[@"browser_action"];
  if (![action isKindOfClass:[NSDictionary class]]) action = manifest[@"page_action"];
  if (![action isKindOfClass:[NSDictionary class]]) action = @{};

  NSString *extID = entry[@"extensionID"];
  if (![extID isKindOfClass:[NSString class]] || extID.length != 32) {
    NSString *keyB64 = manifest[@"key"];
    if ([keyB64 isKindOfClass:[NSString class]] && keyB64.length > 0) {
      NSData *keyData = [[NSData alloc] initWithBase64EncodedString:keyB64
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
      if (keyData.length > 0) {
        extID = SXChromiumIDFromBytes(keyData.bytes, keyData.length);
      }
    }
    if (extID.length != 32) {
      extID = SXChromiumIDFromPath(dir);
    }
  }

  NSString *storeID = [entry[@"storeID"] isKindOfClass:[NSString class]] ? entry[@"storeID"] : nil;
  NSString *rawName = action[@"default_title"] ?: manifest[@"name"] ?: [dir lastPathComponent];
  NSString *name = SXResolveLocalizedMessage(dir, manifest, rawName);
  if (name.length == 0) name = [dir lastPathComponent];
  NSString *version = [manifest[@"version"] isKindOfClass:[NSString class]] ? manifest[@"version"] : @"1.0";
  NSString *desc = [manifest[@"description"] isKindOfClass:[NSString class]]
                       ? SXResolveLocalizedMessage(dir, manifest, manifest[@"description"])
                       : nil;

  NSString *iconPath = SXPickBestIconPath(dir, action[@"default_icon"])
                           ?: SXPickBestIconPath(dir, manifest[@"icons"]);
  NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;

  NSURL *popupURL = nil;
  if ([action[@"default_popup"] isKindOfClass:[NSString class]]) {
    NSString *relPopup = [(NSString *)action[@"default_popup"]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (relPopup.length > 0) {
      NSString *urlStr = [NSString stringWithFormat:@"chrome-extension://%@/%@", extID, relPopup];
      popupURL = [NSURL URLWithString:urlStr];
    }
  }

  BOOL enabled = entry[@"enabled"] ? [entry[@"enabled"] boolValue] : YES;
  BOOL allowInPrivate = entry[@"allowInPrivate"] ? [entry[@"allowInPrivate"] boolValue] : NO;

  NSString *badgeText = nil;
  NSColor *badgeColor = nil;
  {
    SXBrowserTab *activeTab = SXFindActiveVisibleTab();
    int activeTabId = activeTab ? [activeTab chromiumBrowserIdentifier] : -1;
    std::string activeNormURL;
    std::string activeHost;
    BOOL isActiveWebTab = SXExtractNormalizedBadgeURL(activeTab.currentURL, &activeNormURL, &activeHost);

    std::string key = [extID lowercaseString].UTF8String;
    std::string rawText;
    std::string rawColor;
    {
      std::lock_guard<std::mutex> lock(_bridgeMutex);
      auto it = _liveBadges.find(key);
      if (it != _liveBadges.end()) {
        const SXLiveBadgeState &st = it->second;
        if (isActiveWebTab) {
          bool resolvedText = false;
          auto uit = st.urlText.find(activeNormURL);
          if (uit != st.urlText.end()) {
            rawText = uit->second;
            resolvedText = true;
          } else {
            auto hit = st.hostText.find(activeHost);
            if (hit != st.hostText.end()) {
              rawText = hit->second;
              resolvedText = true;
            }
          }
          if (!resolvedText) {
            if (st.hasGlobalText) {
              rawText = st.globalText;
            } else if (activeTabId >= 0) {
              auto tit = st.tabText.find(activeTabId);
              if (tit != st.tabText.end()) {
                rawText = tit->second;
              } else if (st.hasLatestWebText && st.urlText.empty() && st.hostText.empty()) {
                rawText = st.latestWebText;
              }
            }
          }

          auto ucit = st.urlColorSpec.find(activeNormURL);
          if (ucit != st.urlColorSpec.end()) {
            rawColor = ucit->second;
          } else {
            auto hcit = st.hostColorSpec.find(activeHost);
            if (hcit != st.hostColorSpec.end()) {
              rawColor = hcit->second;
            } else if (!st.globalColorSpec.empty()) {
              rawColor = st.globalColorSpec;
            } else if (activeTabId >= 0) {
              auto tcit = st.tabColorSpec.find(activeTabId);
              if (tcit != st.tabColorSpec.end()) {
                rawColor = tcit->second;
              } else if (!st.latestWebColorSpec.empty()) {
                rawColor = st.latestWebColorSpec;
              }
            }
          }
        } else {
          // Non-web page (e.g. Start Page): show ONLY explicit global badges, never leak web-tab counts.
          if (st.hasGlobalText) {
            rawText = st.globalText;
            rawColor = st.globalColorSpec;
          }
        }
      }
    }
    if (!rawText.empty()) {
      badgeText = [NSString stringWithUTF8String:rawText.c_str()];
    }
    if (!rawColor.empty()) {
      NSData *cd = [NSData dataWithBytes:rawColor.data() length:rawColor.size()];
      NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil];
      if ([parsed isKindOfClass:[NSDictionary class]]) {
        badgeColor = SXColorFromBadgeSpec(parsed[@"c"]);
      }
    }
  }

  return [[SXExtensionItem alloc] initWithExtensionID:extID
                                              storeID:storeID
                                                 name:name
                                              version:version
                                 extensionDescription:desc
                                                 icon:icon
                                            badgeText:badgeText
                                           badgeColor:badgeColor
                                             popupURL:popupURL
                                          installPath:dir
                                              enabled:enabled
                                       allowInPrivate:allowInPrivate];
}

- (NSArray<SXExtensionItem *> *)installedExtensions {
  NSMutableArray<SXExtensionItem *> *items = [NSMutableArray array];
  for (NSDictionary *entry in [self.registryEntries copy]) {
    SXExtensionItem *item = [self buildItemFromEntry:entry];
    if (item) {
      [items addObject:item];
    }
  }
  return items;
}

- (nullable SXExtensionItem *)extensionWithIDOrStoreID:(NSString *)identifier {
  if (!identifier.length) return nil;
  NSString *lower = [identifier lowercaseString];
  for (SXExtensionItem *item in [self installedExtensions]) {
    if ([[item.extensionID lowercaseString] isEqualToString:lower] ||
        (item.storeID && [[item.storeID lowercaseString] isEqualToString:lower])) {
      return item;
    }
  }
  return nil;
}

- (BOOL)isStoreIDInstalled:(NSString *)storeID {
  return [self extensionWithIDOrStoreID:storeID] != nil;
}

- (BOOL)isStoreIDBusy:(NSString *)storeID {
  if (!storeID.length) return NO;
  return [self.inFlightStoreIDs containsObject:[storeID lowercaseString]];
}

- (void)registerActiveBrowser:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  _liveBrowsers.push_back(browser);
}

- (void)unregisterActiveBrowser:(CefRefPtr<CefBrowser>)browser {
  CEF_REQUIRE_UI_THREAD();
  if (!browser) return;
  int targetId = browser->GetIdentifier();
  _liveBrowsers.erase(
      std::remove_if(_liveBrowsers.begin(), _liveBrowsers.end(),
                     [targetId](const CefRefPtr<CefBrowser>& b) {
                       return !b || b->GetIdentifier() == targetId;
                     }),
      _liveBrowsers.end());
}

- (void)broadcastCWSStateForStoreID:(NSString *)storeID installed:(BOOL)installed {
  if (!storeID.length) return;
  std::string sid = [storeID lowercaseString].UTF8String;
  bool inst = installed ? true : false;
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      [](SXExtensionManager *mgr, std::string s, bool ins) {
        if (!mgr) return;
        for (const auto& b : mgr->_liveBrowsers) {
          if (!b) continue;
          CefRefPtr<CefFrame> f = b->GetMainFrame();
          if (!f || !f->IsValid()) continue;
          std::string u = f->GetURL().ToString();
          if (u.find("chromewebstore.google.com") != std::string::npos ||
              u.find("chrome.google.com/webstore") != std::string::npos) {
            CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("sx.cws_state");
            CefRefPtr<CefListValue> rargs = reply->GetArgumentList();
            rargs->SetString(0, s);
            rargs->SetBool(1, ins);
            rargs->SetBool(2, false);
            rargs->SetString(3, "");
            f->SendProcessMessage(PID_RENDERER, reply);
          }
        }
      },
      self, sid, inst)));
}

static BOOL SXURLMatchesExtensionPattern(NSString *urlString, NSString *pattern) {
  if (!urlString.length || !pattern.length) return NO;
  if ([pattern isEqualToString:@"<all_urls>"]) {
    return [urlString hasPrefix:@"http://"] || [urlString hasPrefix:@"https://"];
  }
  NSURL *url = [NSURL URLWithString:urlString];
  NSString *scheme = url.scheme.lowercaseString ?: @"";
  NSString *host = url.host.lowercaseString ?: @"";
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

  NSRange sep = [pattern rangeOfString:@"://"];
  if (sep.location == NSNotFound) return NO;
  NSString *patScheme = [[pattern substringToIndex:sep.location] lowercaseString];
  if (![patScheme isEqualToString:@"*"] && ![patScheme isEqualToString:scheme]) return NO;

  NSString *rest = [pattern substringFromIndex:NSMaxRange(sep)];
  NSRange slash = [rest rangeOfString:@"/"];
  NSString *patHost = (slash.location == NSNotFound) ? rest.lowercaseString : [[rest substringToIndex:slash.location] lowercaseString];
  NSString *patPath = (slash.location == NSNotFound) ? @"*" : [rest substringFromIndex:slash.location];

  if (![patHost isEqualToString:@"*"]) {
    if ([patHost hasPrefix:@"*."]) {
      NSString *suffix = [patHost substringFromIndex:2];
      if (![host isEqualToString:suffix] && ![host hasSuffix:[@"." stringByAppendingString:suffix]]) {
        return NO;
      }
    } else if (![host isEqualToString:patHost]) {
      return NO;
    }
  }

  if ([patPath isEqualToString:@"/*"] || [patPath isEqualToString:@"*"]) return YES;
  NSString *urlPath = url.path.length > 0 ? url.path : @"/";
  if (url.query.length > 0) urlPath = [NSString stringWithFormat:@"%@?%@", urlPath, url.query];
  NSPredicate *pred = [NSPredicate predicateWithFormat:@"SELF LIKE %@", patPath];
  return [pred evaluateWithObject:urlPath];
}

static BOOL SXURLMatchesContentScriptEntry(NSString *urlString, NSDictionary *entry) {
  NSArray *matches = [entry[@"matches"] isKindOfClass:[NSArray class]] ? entry[@"matches"] : nil;
  if (!matches.count) return NO;
  BOOL matched = NO;
  for (id p in matches) {
    if ([p isKindOfClass:[NSString class]] && SXURLMatchesExtensionPattern(urlString, (NSString *)p)) {
      matched = YES;
      break;
    }
  }
  if (!matched) return NO;
  NSArray *excludes = [entry[@"exclude_matches"] isKindOfClass:[NSArray class]] ? entry[@"exclude_matches"] : nil;
  for (id p in excludes) {
    if ([p isKindOfClass:[NSString class]] && SXURLMatchesExtensionPattern(urlString, (NSString *)p)) {
      return NO;
    }
  }
  return YES;
}

- (void)injectManifestContentScriptsForExtensionID:(NSString *)extID directory:(NSString *)dir {
  if (!extID.length || !dir.length) return;
  NSString *manifestPath = [dir stringByAppendingPathComponent:@"manifest.json"];
  NSData *mdata = [NSData dataWithContentsOfFile:manifestPath];
  if (!mdata) return;
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]]) return;
  NSArray *contentScripts = [manifest[@"content_scripts"] isKindOfClass:[NSArray class]] ? manifest[@"content_scripts"] : nil;
  if (!contentScripts.count) return;

  NSString *safeExtID = [[extID lowercaseString] stringByReplacingOccurrencesOfString:@"'" withString:@""];
  NSString *dirCopy = [dir copy];
  NSArray *scriptsCopy = [contentScripts copy];

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      [](SXExtensionManager *mgr, NSString *eid, NSString *baseDir, NSArray *csEntries) {
        if (!mgr) return;
        for (const auto& b : mgr->_liveBrowsers) {
          if (!b) continue;
          CefRefPtr<CefFrame> mainFrame = b->GetMainFrame();
          if (!mainFrame || !mainFrame->IsValid()) continue;
          std::string mainURLStd = mainFrame->GetURL().ToString();
          NSString *mainURL = [NSString stringWithUTF8String:mainURLStd.c_str()] ?: @"";
          if (![mainURL hasPrefix:@"http://"] && ![mainURL hasPrefix:@"https://"]) continue;

          for (id rawEntry in csEntries) {
            if (![rawEntry isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *entry = (NSDictionary *)rawEntry;
            BOOL allFrames = [entry[@"all_frames"] boolValue];

            std::vector<CefRefPtr<CefFrame>> targetFrames;
            if (allFrames) {
              std::vector<CefString> frameIds;
              b->GetFrameIdentifiers(frameIds);
              for (const auto& fid : frameIds) {
                CefRefPtr<CefFrame> f = b->GetFrameByIdentifier(fid);
                if (f && f->IsValid()) targetFrames.push_back(f);
              }
            } else {
              targetFrames.push_back(mainFrame);
            }

            NSArray *cssFiles = [entry[@"css"] isKindOfClass:[NSArray class]] ? entry[@"css"] : nil;
            NSArray *jsFiles = [entry[@"js"] isKindOfClass:[NSArray class]] ? entry[@"js"] : nil;

            for (const auto& frame : targetFrames) {
              NSString *fURL = [NSString stringWithUTF8String:frame->GetURL().ToString().c_str()] ?: @"";
              if (!SXURLMatchesContentScriptEntry(fURL, entry)) continue;

              // 1. Instant CSS injection (tagged so disabling/uninstalling can remove it live)
              if (cssFiles.count > 0) {
                NSMutableString *combinedCSS = [NSMutableString string];
                for (id rel in cssFiles) {
                  if (![rel isKindOfClass:[NSString class]]) continue;
                  NSString *full = SXContainedPath(baseDir, (NSString *)rel);
                  if (!full) continue;
                  NSString *cssText = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
                  if (cssText.length > 0) {
                    [combinedCSS appendString:cssText];
                    [combinedCSS appendString:@"\n"];
                  }
                }
                if (combinedCSS.length > 0) {
                  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[eid, combinedCSS] options:0 error:nil];
                  NSString *jsonStr = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
                  if (jsonStr.length > 0) {
                    NSString *injectCSSJS = [NSString stringWithFormat:
                        @"(function(p){try{var id=p[0],css=p[1];"
                        @"var existing=document.querySelector('style[data-sx-ext-css=\"'+id+'\"]');"
                        @"if(existing){existing.textContent=css;return;}"
                        @"var s=document.createElement('style');s.setAttribute('data-sx-ext-css',id);s.textContent=css;"
                        @"(document.head||document.documentElement).appendChild(s);}catch(_){}})(%@);",
                        jsonStr];
                    frame->ExecuteJavaScript(injectCSSJS.UTF8String, frame->GetURL(), 0);
                  }
                }
              }

              // 2. Instant JS content script injection for lightweight scripts that don't require isolated chrome.* APIs
              if (jsFiles.count > 0) {
                NSMutableString *combinedJS = [NSMutableString string];
                for (id rel in jsFiles) {
                  if (![rel isKindOfClass:[NSString class]]) continue;
                  NSString *full = SXContainedPath(baseDir, (NSString *)rel);
                  if (!full) continue;
                  NSString *jsText = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
                  if (jsText.length > 0) {
                    [combinedJS appendString:jsText];
                    [combinedJS appendString:@"\n"];
                  }
                }
                // Only run directly in main world if script does not depend on isolated chrome.runtime/storage APIs
                BOOL needsIsolatedChromeAPI =
                    ([combinedJS rangeOfString:@"chrome.runtime"].location != NSNotFound) ||
                    ([combinedJS rangeOfString:@"chrome.storage"].location != NSNotFound) ||
                    ([combinedJS rangeOfString:@"browser.runtime"].location != NSNotFound) ||
                    ([combinedJS rangeOfString:@"browser.storage"].location != NSNotFound);
                if (combinedJS.length > 0 && !needsIsolatedChromeAPI) {
                  NSString *wrapped = [NSString stringWithFormat:
                      @"(function(){var k='__sxExtInjected_%@';if(window[k])return;window[k]=true;try{\n%@\n}catch(_){}})();",
                      eid, combinedJS];
                  frame->ExecuteJavaScript(wrapped.UTF8String, frame->GetURL(), 0);
                }
              }
            }
          }
        }
      },
      self, safeExtID, dirCopy, scriptsCopy)));
}

- (void)removeInjectedCSSForExtensionID:(NSString *)extID {
  if (!extID.length) return;
  NSString *safeExtID = [[extID lowercaseString] stringByReplacingOccurrencesOfString:@"'" withString:@""];
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      [](SXExtensionManager *mgr, NSString *eid) {
        if (!mgr) return;
        NSString *rmJS = [NSString stringWithFormat:
            @"(function(){try{document.querySelectorAll('style[data-sx-ext-css=\"%@\"]').forEach(function(el){el.remove();});}catch(_){}})();",
            eid];
        for (const auto& b : mgr->_liveBrowsers) {
          if (!b) continue;
          std::vector<CefString> frameIds;
          b->GetFrameIdentifiers(frameIds);
          for (const auto& fid : frameIds) {
            CefRefPtr<CefFrame> f = b->GetFrameByIdentifier(fid);
            if (f && f->IsValid()) {
              f->ExecuteJavaScript(rmJS.UTF8String, f->GetURL(), 0);
            }
          }
        }
      },
      self, safeExtID)));
}

- (void)hotLoadDirectoryIntoChromium:(NSString *)dir
                             storeID:(nullable NSString *)storeID
                          completion:(nullable void (^)(SXExtensionItem * _Nullable, NSError * _Nullable))completion {
  NSString *canonicalDir = [dir stringByStandardizingPath];
  [self ensureServiceWorkerBridgeInDirectory:canonicalDir];
  _liveLoader->LoadUnpacked(
      canonicalDir.UTF8String,
      [self, canonicalDir, storeID, completion](bool success, const std::string& loadedId) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSString *finalID = (success && loadedId.size() == 32)
                                  ? [NSString stringWithUTF8String:loadedId.c_str()]
                                  : nil;
          BOOL loadedNativelyNow = (finalID.length == 32);
          if (finalID.length != 32) {
            NSData *mdata = [NSData dataWithContentsOfFile:
                [canonicalDir stringByAppendingPathComponent:@"manifest.json"]];
            NSDictionary *m = mdata ? [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil] : nil;
            NSString *keyB64 = [m isKindOfClass:[NSDictionary class]] ? m[@"key"] : nil;
            if ([keyB64 isKindOfClass:[NSString class]] && keyB64.length > 0) {
              NSData *kd = [[NSData alloc] initWithBase64EncodedString:keyB64
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
              if (kd.length > 0) {
                finalID = SXChromiumIDFromBytes(kd.bytes, kd.length);
              }
            }
            if (finalID.length != 32) {
              finalID = SXChromiumIDFromPath(canonicalDir);
            }
          }

          if (loadedNativelyNow) {
            [self.nativelyLoadedIDs addObject:[finalID lowercaseString]];
          }

          // Upsert registry entry cleanly.
          NSMutableDictionary *existing = nil;
          for (NSMutableDictionary *e in self.registryEntries) {
            if ([e[@"path"] isEqualToString:canonicalDir] ||
                (storeID.length > 0 && [e[@"storeID"] isEqualToString:storeID]) ||
                [e[@"extensionID"] isEqualToString:finalID]) {
              existing = e;
              break;
            }
          }
          if (!existing) {
            existing = [NSMutableDictionary dictionary];
            [self.registryEntries addObject:existing];
          }
          existing[@"extensionID"] = finalID;
          if (storeID.length > 0) existing[@"storeID"] = storeID;
          existing[@"path"] = canonicalDir;
          existing[@"enabled"] = @YES;
          existing[@"installedAt"] = @((long long)([[NSDate date] timeIntervalSince1970] * 1000));
          [self saveRegistryToDisk];

          SXExtensionItem *item = [self buildItemFromEntry:existing];
          [self injectManifestContentScriptsForExtensionID:finalID directory:canonicalDir];
          [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
          [self broadcastCWSStateForStoreID:(storeID ?: finalID) installed:YES];
          if (completion) {
            completion(item, nil);
          }
        });
      });
}

- (void)injectPublicKeyIfMissing:(NSData *)publicKey intoDirectory:(NSString *)dir {
  if (!publicKey.length) return;
  NSString *manifestPath = [dir stringByAppendingPathComponent:@"manifest.json"];
  NSData *data = [NSData dataWithContentsOfFile:manifestPath];
  if (!data) return;
  NSMutableDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:NSJSONReadingMutableContainers
                                                                    error:nil];
  if (![manifest isKindOfClass:[NSMutableDictionary class]]) return;
  if ([manifest[@"key"] isKindOfClass:[NSString class]] && [(NSString *)manifest[@"key"] length] > 0) {
    return;
  }
  manifest[@"key"] = [publicKey base64EncodedStringWithOptions:0];
  NSData *updated = [NSJSONSerialization dataWithJSONObject:manifest
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:nil];
  if (updated) {
    [updated writeToFile:manifestPath atomically:YES];
  }
}

/// Injects an idempotent MV3 Service Worker active-tab, badge & contextMenus bridge directly at the top
/// of the extension's existing `service_worker` JS file (keeping `manifest.json` 100% untouched).
/// Returns YES if the service worker file on disk was modified.
- (BOOL)ensureServiceWorkerBridgeInDirectory:(NSString *)dir {
  if (!dir.length) return NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *manifestPath = [dir stringByAppendingPathComponent:@"manifest.json"];
  NSData *data = [NSData dataWithContentsOfFile:manifestPath];
  if (!data) return NO;
  NSMutableDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:NSJSONReadingMutableContainers
                                                                    error:nil];
  if (![manifest isKindOfClass:[NSMutableDictionary class]]) return NO;

  NSMutableDictionary *bg = [manifest[@"background"] isKindOfClass:[NSMutableDictionary class]]
                                ? manifest[@"background"]
                                : nil;
  NSString *sw = [bg[@"service_worker"] isKindOfClass:[NSString class]] ? bg[@"service_worker"] : nil;

  // Clean up any legacy wrapper files (`__sx_sw_*` or `sx-sw-*`) and restore original manifest `service_worker`.
  for (NSString *legacyName in @[ @"__sx_sw_bridge.js", @"sx-sw-bridge.js" ]) {
    NSString *p = [dir stringByAppendingPathComponent:legacyName];
    if ([fm fileExistsAtPath:p]) {
      [fm removeItemAtPath:p error:nil];
    }
  }
  if (sw.length &&
      ([[sw lastPathComponent] isEqualToString:@"__sx_sw_entry.js"] ||
       [[sw lastPathComponent] isEqualToString:@"sx-sw-entry.js"])) {
    NSString *cleanLegacy = [sw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *legacyEntryAbs = SXContainedPath(dir, cleanLegacy);
    if (!legacyEntryAbs) return NO;  // manifest points outside the extension directory
    NSString *legacyDirRel = [cleanLegacy stringByDeletingLastPathComponent];
    NSString *recoveredBase = @"background.js";
    NSString *legacyContent = [NSString stringWithContentsOfFile:legacyEntryAbs encoding:NSUTF8StringEncoding error:nil];
    if (legacyContent.length) {
      NSRange r1 = [legacyContent rangeOfString:@"'./"];
      if (r1.location != NSNotFound) {
        NSUInteger start = r1.location + 3;
        NSRange r2 = [legacyContent rangeOfString:@"'" options:0 range:NSMakeRange(start, legacyContent.length - start)];
        if (r2.location != NSNotFound && r2.location > start) {
          recoveredBase = [legacyContent substringWithRange:NSMakeRange(start, r2.location - start)];
        }
      }
    }
    [fm removeItemAtPath:legacyEntryAbs error:nil];
    sw = legacyDirRel.length > 0 ? [legacyDirRel stringByAppendingPathComponent:recoveredBase] : recoveredBase;
    bg[@"service_worker"] = sw;
    manifest[@"background"] = bg;
    NSData *restored = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (restored) {
      [restored writeToFile:manifestPath atomically:YES];
    }
  }

  // Convert Safari/Firefox-style MV3 `background.scripts` manifests (e.g. Content Shield)
  // into a Chromium-compatible `background.service_worker` wrapper (`sx-bg-sw.js`) so their
  // background script actually boots and handles `runtime.sendMessage`.
  if ([manifest[@"manifest_version"] integerValue] == 3 && !sw.length &&
      [bg[@"scripts"] isKindOfClass:[NSArray class]]) {
    NSArray *scripts = bg[@"scripts"];
    NSMutableArray<NSString *> *quoted = [NSMutableArray array];
    for (id s in scripts) {
      if (![s isKindOfClass:[NSString class]]) continue;
      NSString *clean = [(NSString *)s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
      if (!clean.length) continue;
      NSString *esc = [clean stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
      esc = [esc stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
      [quoted addObject:[NSString stringWithFormat:@"'/%@'", esc]];
    }
    if (quoted.count > 0) {
      NSString *wrapperName = @"sx-bg-sw.js";
      NSString *wrapperAbs = [dir stringByAppendingPathComponent:wrapperName];
      NSString *wrapperBody = [NSString stringWithFormat:
          @"if(typeof globalThis.browser==='undefined'&&typeof chrome!=='undefined'){globalThis.browser=chrome;}\n"
          @"importScripts(%@);\n",
          [quoted componentsJoinedByString:@", "]];
      [wrapperBody writeToFile:wrapperAbs atomically:YES encoding:NSUTF8StringEncoding error:nil];
      [bg removeObjectForKey:@"scripts"];
      [bg removeObjectForKey:@"persistent"];
      bg[@"service_worker"] = wrapperName;
      manifest[@"background"] = bg;
      NSData *updated = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
      if (updated) {
        [updated writeToFile:manifestPath atomically:YES];
      }
      sw = wrapperName;
      NSLog(@"[Safarium] Converted MV3 background.scripts -> %@ in %@", wrapperName, [dir lastPathComponent]);
    }
  }

  if ([manifest[@"manifest_version"] integerValue] != 3 || !sw.length) return NO;

  [self startBridgeServerIfNeeded];
  if (_bridgePort == 0 || _bridgeToken.empty()) return NO;

  NSString *cleanSW = [sw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
  if (!cleanSW.length) return NO;
  NSString *swAbsPath = SXContainedPath(dir, cleanSW);
  if (!swAbsPath) return NO;  // manifest service_worker escapes the extension directory
  NSString *swContent = [NSString stringWithContentsOfFile:swAbsPath encoding:NSUTF8StringEncoding error:nil];
  if (!swContent.length) return NO;

  // Strip any previous V2..V8 bridge block before injecting current session's port & token
  NSString *cleanBody = swContent;
  for (NSArray<NSString *> *pair in @[
         @[ @"/*SX_SW_BRIDGE_START_V2*/", @"/*SX_SW_BRIDGE_END_V2*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V3*/", @"/*SX_SW_BRIDGE_END_V3*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V4*/", @"/*SX_SW_BRIDGE_END_V4*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V5*/", @"/*SX_SW_BRIDGE_END_V5*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V6*/", @"/*SX_SW_BRIDGE_END_V6*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V7*/", @"/*SX_SW_BRIDGE_END_V7*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V8*/", @"/*SX_SW_BRIDGE_END_V8*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V9*/", @"/*SX_SW_BRIDGE_END_V9*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V10*/", @"/*SX_SW_BRIDGE_END_V10*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V11*/", @"/*SX_SW_BRIDGE_END_V11*/" ],
         @[ @"/*SX_SW_BRIDGE_START_V12*/", @"/*SX_SW_BRIDGE_END_V12*/" ]
       ]) {
    NSRange sRange = [cleanBody rangeOfString:pair[0]];
    NSRange eRange = [cleanBody rangeOfString:pair[1]];
    if (sRange.location != NSNotFound && eRange.location != NSNotFound && eRange.location > sRange.location) {
      NSUInteger afterEnd = NSMaxRange(eRange);
      while (afterEnd < cleanBody.length &&
             ([cleanBody characterAtIndex:afterEnd] == '\n' || [cleanBody characterAtIndex:afterEnd] == '\r')) {
        afterEnd++;
      }
      cleanBody = [[cleanBody substringToIndex:sRange.location]
          stringByAppendingString:[cleanBody substringFromIndex:afterEnd]];
    }
  }

  NSString *startMarker = @"/*SX_SW_BRIDGE_START_V12*/";
  NSString *endMarker = @"/*SX_SW_BRIDGE_END_V12*/";
  NSString *loopbackHost = [NSString stringWithFormat:@"%d.%d.%d.%d", 127, 0, 0, 1];
  NSString *baseURL = [NSString stringWithFormat:@"http://%@:%u", loopbackHost, (unsigned)_bridgePort];
  NSString *canonDir = [[dir stringByStandardizingPath] stringByResolvingSymlinksInPath];
  const std::string extKey = SXBridgeKeyForDirectory(canonDir);
  {
    std::lock_guard<std::mutex> lock(_bridgeMutex);
    _bridgeDirByKey[extKey] = canonDir.UTF8String;
    _bridgeTabAccessByKey[extKey] = SXManifestGrantsTabAccess(canonDir);
  }
  NSString *tokStr = [NSString stringWithUTF8String:SXBridgeTokenForKey(_bridgeToken, extKey).c_str()];
  NSString *keyStr = [NSString stringWithUTF8String:extKey.c_str()];

  NSString *bridgeBlock = [NSString stringWithFormat:@"%@\n"
      "(function(){try{\n"
      "if(globalThis.__sxSwBridgeInstalled)return;globalThis.__sxSwBridgeInstalled=true;\n"
      "if(typeof chrome==='undefined'||!chrome)return;\n"
      "const BASE='%@',TOK='%@',KEY='%@';\n"
      "const EXT_ID=(chrome.runtime&&chrome.runtime.id)||'';\n"
      "const postJSON=(path,obj)=>{if(!EXT_ID)return;try{fetch(BASE+path+'?token='+TOK+'&key='+KEY,{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:JSON.stringify(obj)}).catch(()=>{});}catch(_){}};\n"
      "const isWebTab=(t)=>!!(t&&typeof t.id==='number'&&t.id>=0&&typeof t.url==='string'&&/^https?:\\/\\//i.test(t.url));\n"
      "const normUrl=(u)=>String(u||'').replace(/\\/+$/,'');\n"
      "const hostOf=(u)=>{try{return new URL(u).host.toLowerCase();}catch(_){return '';}};\n"
      "let lastActiveTabId=null,lastActiveTab=null,lastTabSeq=0,sxActiveTab=null,lastRealTab=null;\n"
      "const tabUrls=new Map(),synthTabs=new Map(),realTabsById=new Map(),realTabsByUrl=new Map(),reportedRealTabs=new Map();\n"
      "const tabActivatedListeners=new Set(),tabUpdatedListeners=new Set();\n"
      "const findRealTabForUrl=(url)=>{\n"
      "  if(!url)return null;\n"
      "  const exact=realTabsByUrl.get(url);\n"
      "  if(exact)return exact;\n"
      "  const nu=normUrl(url);\n"
      "  for(const t of realTabsById.values()){if(t&&normUrl(t.url)===nu)return t;}\n"
      "  const h=hostOf(url);\n"
      "  if(h&&lastRealTab&&hostOf(lastRealTab.url)===h)return lastRealTab;\n"
      "  if(h){for(const t of realTabsById.values()){if(t&&hostOf(t.url)===h)return t;}}\n"
      "  return null;\n"
      "};\n"
      "const remapRealTabId=(tid)=>{\n"
      "  if(typeof tid==='number'&&realTabsById.has(tid))return tid;\n"
      "  const st=(typeof tid==='number'&&synthTabs.get(tid))||null;\n"
      "  const targetUrl=(st&&st.url)||(sxActiveTab&&sxActiveTab.url)||'';\n"
      "  const match=findRealTabForUrl(targetUrl)||lastRealTab;\n"
      "  return (match&&typeof match.id==='number')?match.id:tid;\n"
      "};\n"
      "const rememberRealTab=(tab)=>{\n"
      "  if(!tab||typeof tab.id!=='number'||synthTabs.has(tab.id))return;\n"
      "  if(typeof tab.url==='string'&&tab.url.length>0)tabUrls.set(tab.id,tab.url);\n"
      "  if(!isWebTab(tab))return;\n"
      "  const copy=Object.assign({},tab,{active:true,highlighted:true,selected:true});\n"
      "  realTabsById.set(tab.id,copy);\n"
      "  realTabsByUrl.set(tab.url,copy);\n"
      "  lastRealTab=copy;\n"
      "  lastActiveTabId=tab.id;\n"
      "  lastActiveTab=copy;\n"
      "  if(reportedRealTabs.get(tab.id)!==tab.url){\n"
      "    reportedRealTabs.set(tab.id,tab.url);\n"
      "    postJSON('/real-tab',{extId:EXT_ID,tabId:tab.id,url:tab.url});\n"
      "  }\n"
      "  if(sxActiveTab&&synthTabs.has(sxActiveTab.id)&&(normUrl(sxActiveTab.url)===normUrl(tab.url)||hostOf(sxActiveTab.url)===hostOf(tab.url))){\n"
      "    sxActiveTab=copy;\n"
      "    const actInfo={tabId:copy.id,windowId:typeof copy.windowId==='number'?copy.windowId:1};\n"
      "    for(const fn of tabActivatedListeners){try{fn(actInfo);}catch(_){}}\n"
      "    const changeInfo={url:copy.url,status:'complete'};\n"
      "    for(const fn of tabUpdatedListeners){try{fn(copy.id,changeInfo,Object.assign({},copy));}catch(_){}}\n"
      "  }\n"
      "};\n"
      "const rawTabs=chrome.tabs||null;\n"
      "const origQuery=(rawTabs&&typeof rawTabs.query==='function')?rawTabs.query.bind(rawTabs):null;\n"
      "const origGet=(rawTabs&&typeof rawTabs.get==='function')?rawTabs.get.bind(rawTabs):null;\n"
      "const origSendMessage=(rawTabs&&typeof rawTabs.sendMessage==='function')?rawTabs.sendMessage.bind(rawTabs):null;\n"
      "const resolveTabUrl=(tid,cb)=>{\n"
      "  if(typeof tid!=='number'||tid<0){cb(null);return;}\n"
      "  const cached=tabUrls.get(tid);\n"
      "  if(cached){cb(cached);return;}\n"
      "  const rt=realTabsById.get(tid);\n"
      "  if(rt&&rt.url){cb(rt.url);return;}\n"
      "  const st=synthTabs.get(tid);\n"
      "  if(st&&st.url){cb(st.url);return;}\n"
      "  if(sxActiveTab&&sxActiveTab.id===tid&&sxActiveTab.url){cb(sxActiveTab.url);return;}\n"
      "  if(origGet){try{origGet(tid,(tab)=>{if(chrome.runtime&&chrome.runtime.lastError){cb(sxActiveTab?sxActiveTab.url:null);return;}if(tab&&typeof tab.url==='string'){tabUrls.set(tid,tab.url);cb(tab.url);}else{cb(sxActiveTab?sxActiveTab.url:null);}});return;}catch(_){}}\n"
      "  cb(sxActiveTab?sxActiveTab.url:null);\n"
      "};\n"
      "const lastSentBadges=new Map();\n"
      "const reportBadge=(tid,url,txt)=>{\n"
      "  const key=(tid===null?'global':(url||('tab:'+tid)));\n"
      "  if(lastSentBadges.get(key)===txt)return;\n"
      "  lastSentBadges.set(key,txt);\n"
      "  postJSON('/badge',{extId:EXT_ID,tabId:tid,tabUrl:url,text:txt});\n"
      "};\n"
      "const getAct=()=>chrome.action||chrome.browserAction||(typeof browser!=='undefined'&&browser&&(browser.action||browser.browserAction))||null;\n"
      "const syncAllBadges=()=>{\n"
      "  try{\n"
      "    const act=getAct();\n"
      "    if(!act||typeof act.getBadgeText!=='function')return;\n"
      "    try{act.getBadgeText({},(txt)=>{if(chrome.runtime&&chrome.runtime.lastError)return;if(typeof txt==='string'&&txt.length>0)reportBadge(null,null,txt);});}catch(_){}\n"
      "    if(origQuery){\n"
      "      origQuery({},(tabs)=>{\n"
      "        if(chrome.runtime&&chrome.runtime.lastError||!Array.isArray(tabs))return;\n"
      "        for(const t of tabs){\n"
      "          if(!isWebTab(t))continue;\n"
      "          tabUrls.set(t.id,t.url);\n"
      "          try{act.getBadgeText({tabId:t.id},(txt)=>{if(chrome.runtime&&chrome.runtime.lastError)return;if(typeof txt==='string')reportBadge(t.id,t.url,txt);});}catch(_){}\n"
      "        }\n"
      "      });\n"
      "    }\n"
      "  }catch(_){}\n"
      "};\n"
      "const makeSynthTab=(id,url,title)=>({\n"
      "  id:(typeof id==='number'&&id>0)?id:1,\n"
      "  index:0,windowId:1,active:true,highlighted:true,selected:true,pinned:false,incognito:false,\n"
      "  status:'complete',url:url||'',pendingUrl:url||'',title:title||'',width:1200,height:800\n"
      "});\n"
      "const respondMaybeCb=(val,cb)=>{\n"
      "  if(typeof cb==='function'){Promise.resolve().then(()=>cb(val));return;}\n"
      "  return Promise.resolve(val);\n"
      "};\n"
      "const safeNativeAction=(origFn,details,cb)=>{\n"
      "  const tid=(details&&typeof details.tabId==='number')?details.tabId:null;\n"
      "  if(tid!==null&&synthTabs.has(tid)){\n"
      "    return respondMaybeCb(undefined,cb);\n"
      "  }\n"
      "  try{\n"
      "    if(typeof cb==='function'){\n"
      "      let called=false;\n"
      "      const safeCb=(...a)=>{if(called)return;called=true;try{void (chrome.runtime&&chrome.runtime.lastError);}catch(_){} try{cb(...a);}catch(_){}};\n"
      "      try{origFn(details,safeCb);}catch(_){safeCb();}\n"
      "      return;\n"
      "    }\n"
      "    const res=origFn(details);\n"
      "    if(res&&typeof res.then==='function')return res.catch(()=>undefined);\n"
      "    return Promise.resolve(res);\n"
      "  }catch(_){return respondMaybeCb(undefined,cb);}\n"
      "};\n"
      "const applyNativeActiveTab=(tabId,url,title)=>{\n"
      "  const prev=sxActiveTab;\n"
      "  const cleanUrl=typeof url==='string'?url:'';\n"
      "  if(!/^https?:\\/\\//i.test(cleanUrl)){\n"
      "    sxActiveTab=null;\n"
      "    return;\n"
      "  }\n"
      "  const realMatch=findRealTabForUrl(cleanUrl);\n"
      "  let tabObj;\n"
      "  if(realMatch){\n"
      "    tabObj=Object.assign({},realMatch,{url:realMatch.url||cleanUrl,active:true,highlighted:true,selected:true});\n"
      "    realTabsById.set(tabObj.id,tabObj);\n"
      "    realTabsByUrl.set(cleanUrl,tabObj);\n"
      "    tabUrls.set(tabObj.id,tabObj.url);\n"
      "  }else{\n"
      "    const synthId=(typeof tabId==='number'&&tabId>0)?(100000+tabId):100001;\n"
      "    tabObj=makeSynthTab(synthId,cleanUrl,title);\n"
      "    synthTabs.set(synthId,tabObj);\n"
      "    tabUrls.set(synthId,cleanUrl);\n"
      "  }\n"
      "  sxActiveTab=tabObj;\n"
      "  const idChanged=!prev||prev.id!==tabObj.id;\n"
      "  const urlChanged=!prev||prev.url!==tabObj.url;\n"
      "  if(idChanged){\n"
      "    const actInfo={tabId:tabObj.id,windowId:typeof tabObj.windowId==='number'?tabObj.windowId:1};\n"
      "    for(const fn of tabActivatedListeners){try{fn(actInfo);}catch(_){}}\n"
      "  }\n"
      "  if(idChanged||urlChanged){\n"
      "    const changeInfo={url:tabObj.url,status:'complete'};\n"
      "    for(const fn of tabUpdatedListeners){try{fn(tabObj.id,changeInfo,Object.assign({},tabObj));}catch(_){}}\n"
      "  }\n"
      "  setTimeout(syncAllBadges,350);\n"
      "};\n"
      "if(origQuery){\n"
      "  try{origQuery({},(tabs)=>{if(chrome.runtime&&chrome.runtime.lastError)return;if(Array.isArray(tabs)){for(const t of tabs){if(t&&typeof t.id==='number'&&typeof t.url==='string')tabUrls.set(t.id,t.url);if(isWebTab(t))realTabsById.set(t.id,t);}}});}catch(_){}\n"
      "  try{chrome.runtime&&chrome.runtime.onMessage&&chrome.runtime.onMessage.addListener((_m,s)=>{if(s&&s.tab)rememberRealTab(s.tab);});}catch(_){}\n"
      "  try{chrome.runtime&&chrome.runtime.onConnect&&chrome.runtime.onConnect.addListener((p)=>{if(p&&p.sender&&p.sender.tab)rememberRealTab(p.sender.tab);});}catch(_){}\n"
      "  try{rawTabs.onUpdated&&rawTabs.onUpdated.addListener((tid,ci,tab)=>{if(typeof tid==='number'&&ci&&typeof ci.url==='string')tabUrls.set(tid,ci.url);if(tab&&typeof tab.id==='number'&&typeof tab.url==='string')tabUrls.set(tab.id,tab.url);if(tab&&isWebTab(tab)&&((ci&&(ci.url||ci.status==='complete'))||lastActiveTabId===null||tab.id===lastActiveTabId))rememberRealTab(tab);if(ci&&(ci.status==='complete'||ci.url)){setTimeout(syncAllBadges,350);}});}catch(_){}\n"
      "  try{rawTabs.onActivated&&rawTabs.onActivated.addListener((info)=>{if(!info||typeof info.tabId!=='number'||!origGet)return;try{origGet(info.tabId,(tab)=>{if(chrome.runtime&&chrome.runtime.lastError)return;if(tab)rememberRealTab(tab);setTimeout(syncAllBadges,250);});}catch(_){}});}catch(_){}\n"
      "  try{rawTabs.onRemoved&&rawTabs.onRemoved.addListener((tid)=>{tabUrls.delete(tid);realTabsById.delete(tid);if(tid===lastActiveTabId){lastActiveTabId=null;lastActiveTab=null;}});}catch(_){}\n"
      "  try{chrome.webNavigation&&chrome.webNavigation.onCommitted&&chrome.webNavigation.onCommitted.addListener((d)=>{if(!d||d.frameId!==0||typeof d.tabId!=='number'||!/^https?:\\/\\//i.test(d.url||''))return;tabUrls.set(d.tabId,d.url);lastActiveTabId=d.tabId;if(origGet){try{origGet(d.tabId,(tab)=>{if(chrome.runtime&&chrome.runtime.lastError)return;if(tab)rememberRealTab(tab);});}catch(_){}}setTimeout(syncAllBadges,450);});}catch(_){}\n"
      "  const callOrigQuery=(q)=>new Promise((resolve)=>{try{origQuery(q||{},(tabs)=>{if(chrome.runtime&&chrome.runtime.lastError)return resolve([]);resolve(Array.isArray(tabs)?tabs:[]);});}catch(_){resolve([]);}});\n"
      "  const patchTabsNs=(ns)=>{\n"
      "    if(!ns||!ns.tabs||ns.__sxSwTabsPatched)return;\n"
      "    const tabsObj=ns.tabs;\n"
      "    const winCurrent=(ns.windows&&typeof ns.windows.WINDOW_ID_CURRENT==='number')?ns.windows.WINDOW_ID_CURRENT:-2;\n"
      "    const wrappedQuery=function(queryInfo,cb){\n"
      "      const hasCb=typeof cb==='function';\n"
      "      const q=queryInfo&&typeof queryInfo==='object'?queryInfo:{};\n"
      "      const isAllLookup=Object.keys(q).length===0;\n"
      "      const isActiveLookup=!!(q.active===true&&!q.url&&!q.windowType&&(q.currentWindow===true||q.lastFocusedWindow===true||q.windowId===winCurrent||Object.keys(q).length===1));\n"
      "      if(!isActiveLookup&&!isAllLookup){return hasCb?origQuery(queryInfo,cb):origQuery(queryInfo);}\n"
      "      const p=Promise.all([callOrigQuery(q),callOrigQuery({})]).then(([origTabs,allTabs])=>{\n"
      "        const liveWebTabs=allTabs.filter(isWebTab);\n"
      "        for(const t of liveWebTabs){tabUrls.set(t.id,t.url);realTabsById.set(t.id,t);realTabsByUrl.set(t.url,t);}\n"
      "        if(isActiveLookup){\n"
      "          if(sxActiveTab&&isWebTab(sxActiveTab)){\n"
      "            const liveMatch=liveWebTabs.find((t)=>normUrl(t.url)===normUrl(sxActiveTab.url));\n"
      "            if(liveMatch){rememberRealTab(liveMatch);return [Object.assign({},liveMatch,{active:true,highlighted:true,selected:true})];}\n"
      "            const realCached=findRealTabForUrl(sxActiveTab.url);\n"
      "            if(realCached){return [Object.assign({},realCached,{active:true,highlighted:true,selected:true})];}\n"
      "            return [Object.assign({},sxActiveTab)];\n"
      "          }\n"
      "          if(lastActiveTabId!==null){\n"
      "            const liveMatch=liveWebTabs.find((t)=>t.id===lastActiveTabId);\n"
      "            if(liveMatch){lastActiveTab=Object.assign({},liveMatch,{active:true,highlighted:true,selected:true});return [lastActiveTab];}\n"
      "          }\n"
      "          const origWeb=origTabs.find(isWebTab);\n"
      "          if(origWeb){rememberRealTab(origWeb);return [Object.assign({},origWeb,{active:true,highlighted:true,selected:true})];}\n"
      "          if(liveWebTabs.length>0){const chosen=liveWebTabs.find((t)=>t.active)||liveWebTabs[liveWebTabs.length-1];rememberRealTab(chosen);return [Object.assign({},chosen,{active:true,highlighted:true,selected:true})];}\n"
      "          if(lastActiveTab&&isWebTab(lastActiveTab)){return [Object.assign({},lastActiveTab)];}\n"
      "          return origTabs;\n"
      "        }\n"
      "        if(sxActiveTab&&isWebTab(sxActiveTab)&&!allTabs.some((t)=>t&&t.id===sxActiveTab.id)){\n"
      "          const realCached=findRealTabForUrl(sxActiveTab.url);\n"
      "          const chosen=realCached?Object.assign({},realCached,{active:true,highlighted:true,selected:true}):Object.assign({},sxActiveTab);\n"
      "          if(!allTabs.some((t)=>t&&t.id===chosen.id))return [chosen].concat(allTabs);\n"
      "        }\n"
      "        return allTabs;\n"
      "      });\n"
      "      if(hasCb){p.then((res)=>cb(res));return;}\n"
      "      return p;\n"
      "    };\n"
      "    const wrappedGet=function(tid,cb){\n"
      "      if(typeof tid==='number'&&synthTabs.has(tid)){\n"
      "        return respondMaybeCb(Object.assign({},synthTabs.get(tid)),cb);\n"
      "      }\n"
      "      if(origGet){\n"
      "        const p=new Promise((resolve)=>{\n"
      "          try{\n"
      "            origGet(tid,(t)=>{\n"
      "              if((chrome.runtime&&chrome.runtime.lastError)||!t){\n"
      "                if(typeof tid==='number'&&realTabsById.has(tid))return resolve(Object.assign({},realTabsById.get(tid)));\n"
      "                if(sxActiveTab&&sxActiveTab.id===tid)return resolve(Object.assign({},sxActiveTab));\n"
      "                return resolve(undefined);\n"
      "              }\n"
      "              resolve(t);\n"
      "            });\n"
      "          }catch(_){resolve((typeof tid==='number'&&realTabsById.has(tid))?Object.assign({},realTabsById.get(tid)):(sxActiveTab&&sxActiveTab.id===tid?Object.assign({},sxActiveTab):undefined));}\n"
      "        });\n"
      "        if(typeof cb==='function'){p.then((r)=>cb(r));return;}\n"
      "        return p;\n"
      "      }\n"
      "      const fallback=(typeof tid==='number'&&realTabsById.get(tid))||sxActiveTab;\n"
      "      return respondMaybeCb(fallback?Object.assign({},fallback):undefined,cb);\n"
      "    };\n"
      "    const wrappedCreate=function(props,cb){\n"
      "      let u=(props&&props.url)?String(props.url):'';\n"
      "      if(u&&!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(u)){try{if(chrome.runtime&&chrome.runtime.getURL)u=chrome.runtime.getURL(u.replace(/^\\/+/,''));}catch(_){}}\n"
      "      if(u)postJSON('/open-tab',{extId:EXT_ID,url:u});\n"
      "      const created=makeSynthTab(Math.floor(Math.random()*90000)+200000,u,'');\n"
      "      return respondMaybeCb(created,cb);\n"
      "    };\n"
      "    const wrappedSendMessage=origSendMessage?function(tid,msg,opts,cb){\n"
      "      const realTid=remapRealTabId(tid);\n"
      "      if(typeof opts==='function'){return origSendMessage(realTid,msg,opts);}\n"
      "      if(typeof cb==='function'){return origSendMessage(realTid,msg,opts,cb);}\n"
      "      return opts!==undefined?origSendMessage(realTid,msg,opts):origSendMessage(realTid,msg);\n"
      "    }:null;\n"
      "    const rawOnAct=tabsObj.onActivated||null;\n"
      "    const origActAdd=(rawOnAct&&typeof rawOnAct.addListener==='function')?rawOnAct.addListener.bind(rawOnAct):null;\n"
      "    const origActRem=(rawOnAct&&typeof rawOnAct.removeListener==='function')?rawOnAct.removeListener.bind(rawOnAct):null;\n"
      "    const wrappedActAdd=origActAdd?function(fn){if(typeof fn==='function'){tabActivatedListeners.add(fn);if(sxActiveTab){const sid=sxActiveTab.id;setTimeout(()=>{try{fn({tabId:sid,windowId:1});}catch(_){}},50);}}return origActAdd(fn);}:null;\n"
      "    const wrappedActRem=origActRem?function(fn){tabActivatedListeners.delete(fn);return origActRem(fn);}:null;\n"
      "    const rawOnUpd=tabsObj.onUpdated||null;\n"
      "    const origUpdAdd=(rawOnUpd&&typeof rawOnUpd.addListener==='function')?rawOnUpd.addListener.bind(rawOnUpd):null;\n"
      "    const origUpdRem=(rawOnUpd&&typeof rawOnUpd.removeListener==='function')?rawOnUpd.removeListener.bind(rawOnUpd):null;\n"
      "    const wrappedUpdAdd=origUpdAdd?function(fn){if(typeof fn==='function'){tabUpdatedListeners.add(fn);if(sxActiveTab){const st=Object.assign({},sxActiveTab);setTimeout(()=>{try{fn(st.id,{url:st.url,status:'complete'},st);}catch(_){}},80);}}return origUpdAdd(fn);}:null;\n"
      "    const wrappedUpdRem=origUpdRem?function(fn){tabUpdatedListeners.delete(fn);return origUpdRem(fn);}:null;\n"
      "    let directOk=true;\n"
      "    const trySet=(obj,k,fn)=>{if(!obj||!fn)return;try{Object.defineProperty(obj,k,{value:fn,configurable:true,writable:true});}catch(_){try{obj[k]=fn;}catch(_2){}} if(obj[k]!==fn)directOk=false;};\n"
      "    trySet(tabsObj,'query',wrappedQuery);\n"
      "    trySet(tabsObj,'get',wrappedGet);\n"
      "    trySet(tabsObj,'create',wrappedCreate);\n"
      "    trySet(tabsObj,'sendMessage',wrappedSendMessage);\n"
      "    trySet(rawOnAct,'addListener',wrappedActAdd);\n"
      "    trySet(rawOnAct,'removeListener',wrappedActRem);\n"
      "    trySet(rawOnUpd,'addListener',wrappedUpdAdd);\n"
      "    trySet(rawOnUpd,'removeListener',wrappedUpdRem);\n"
      "    if(!directOk){\n"
      "      try{\n"
      "        const wrapEvt=(raw,addFn,remFn)=>raw?new Proxy(raw,{get(target,p){if(p==='addListener'&&addFn)return addFn;if(p==='removeListener'&&remFn)return remFn;const v=Reflect.get(target,p,target);return typeof v==='function'?v.bind(target):v;}}):null;\n"
      "        const onActProxy=wrapEvt(rawOnAct,wrappedActAdd,wrappedActRem);\n"
      "        const onUpdProxy=wrapEvt(rawOnUpd,wrappedUpdAdd,wrappedUpdRem);\n"
      "        const tabsProxy=new Proxy(tabsObj,{get(target,prop){\n"
      "          if(prop==='query')return wrappedQuery;\n"
      "          if(prop==='get')return wrappedGet;\n"
      "          if(prop==='create')return wrappedCreate;\n"
      "          if(prop==='sendMessage'&&wrappedSendMessage)return wrappedSendMessage;\n"
      "          if(prop==='onActivated'&&onActProxy)return onActProxy;\n"
      "          if(prop==='onUpdated'&&onUpdProxy)return onUpdProxy;\n"
      "          const v=Reflect.get(target,prop,target);\n"
      "          return typeof v==='function'?v.bind(target):v;\n"
      "        }});\n"
      "        Object.defineProperty(ns,'tabs',{value:tabsProxy,configurable:true,writable:true});\n"
      "      }catch(_){}\n"
      "    }\n"
      "    if(ns.scripting){\n"
      "      const sc=ns.scripting;\n"
      "      const wrapScFn=(fnName)=>{\n"
      "        if(typeof sc[fnName]!=='function')return null;\n"
      "        const orig=sc[fnName].bind(sc);\n"
      "        return function(inj,cb){\n"
      "          try{if(inj&&inj.target&&typeof inj.target.tabId==='number'){inj=Object.assign({},inj,{target:Object.assign({},inj.target,{tabId:remapRealTabId(inj.target.tabId)})});}}catch(_){}\n"
      "          return typeof cb==='function'?orig(inj,cb):orig(inj);\n"
      "        };\n"
      "      };\n"
      "      const wrappedMap={};\n"
      "      for(const fnName of ['executeScript','insertCSS','removeCSS']){\n"
      "        const w=wrapScFn(fnName);\n"
      "        if(w){\n"
      "          wrappedMap[fnName]=w;\n"
      "          try{Object.defineProperty(sc,fnName,{value:w,configurable:true,writable:true});}catch(_){try{sc[fnName]=w;}catch(_2){}}\n"
      "        }\n"
      "      }\n"
      "      const needsProxy=Object.keys(wrappedMap).some((k)=>sc[k]!==wrappedMap[k]);\n"
      "      if(needsProxy){\n"
      "        try{const scProxy=new Proxy(sc,{get(t,p){if(wrappedMap[p])return wrappedMap[p];const v=Reflect.get(t,p,t);return typeof v==='function'?v.bind(t):v;}});Object.defineProperty(ns,'scripting',{value:scProxy,configurable:true,writable:true});}catch(_){}\n"
      "      }\n"
      "    }\n"
      "    try{ns.__sxSwTabsPatched=true;}catch(_){}\n"
      "  };\n"
      "  patchTabsNs(chrome);\n"
      "  if(typeof browser!=='undefined'&&browser&&browser!==chrome)patchTabsNs(browser);\n"
      "}\n"
      "const patchActionNs=(ns,propName)=>{\n"
      "  const act=ns&&ns[propName];\n"
      "  if(!act||act.__sxBadgePatched)return;\n"
      "  const origText=typeof act.setBadgeText==='function'?act.setBadgeText.bind(act):null;\n"
      "  const origColor=typeof act.setBadgeBackgroundColor==='function'?act.setBadgeBackgroundColor.bind(act):null;\n"
      "  const origIcon=typeof act.setIcon==='function'?act.setIcon.bind(act):null;\n"
      "  const wrappedText=origText?function(details,cb){\n"
      "    try{\n"
      "      const d=details||{};\n"
      "      const tid=typeof d.tabId==='number'?d.tabId:null;\n"
      "      const txt=d.text==null?'':String(d.text);\n"
      "      if(tid!==null){resolveTabUrl(tid,(u)=>reportBadge(tid,u,txt));}\n"
      "      else{reportBadge(null,null,txt);}\n"
      "    }catch(_){}\n"
      "    return safeNativeAction(origText,details,cb);\n"
      "  }:null;\n"
      "  const wrappedColor=origColor?function(details,cb){\n"
      "    try{\n"
      "      const d=details||{};\n"
      "      if(d.color!==undefined){\n"
      "        const tid=typeof d.tabId==='number'?d.tabId:null;\n"
      "        if(tid!==null){resolveTabUrl(tid,(u)=>postJSON('/badge',{extId:EXT_ID,tabId:tid,tabUrl:u,color:d.color}));}\n"
      "        else{postJSON('/badge',{extId:EXT_ID,tabId:null,tabUrl:null,color:d.color});}\n"
      "      }\n"
      "    }catch(_){}\n"
      "    return safeNativeAction(origColor,details,cb);\n"
      "  }:null;\n"
      "  const wrappedIcon=origIcon?function(details,cb){\n"
      "    return safeNativeAction(origIcon,details,cb);\n"
      "  }:null;\n"
      "  let directOk=true;\n"
      "  if(wrappedText){try{Object.defineProperty(act,'setBadgeText',{value:wrappedText,configurable:true,writable:true});}catch(_){try{act.setBadgeText=wrappedText;}catch(_2){}} if(act.setBadgeText!==wrappedText)directOk=false;}\n"
      "  if(wrappedColor){try{Object.defineProperty(act,'setBadgeBackgroundColor',{value:wrappedColor,configurable:true,writable:true});}catch(_){try{act.setBadgeBackgroundColor=wrappedColor;}catch(_2){}} if(act.setBadgeBackgroundColor!==wrappedColor)directOk=false;}\n"
      "  if(wrappedIcon){try{Object.defineProperty(act,'setIcon',{value:wrappedIcon,configurable:true,writable:true});}catch(_){try{act.setIcon=wrappedIcon;}catch(_2){}} if(act.setIcon!==wrappedIcon)directOk=false;}\n"
      "  if(!directOk){\n"
      "    try{\n"
      "      const actProxy=new Proxy(act,{get(target,p){\n"
      "        if(p==='__sxBadgePatched')return true;\n"
      "        if(p==='setBadgeText'&&wrappedText)return wrappedText;\n"
      "        if(p==='setBadgeBackgroundColor'&&wrappedColor)return wrappedColor;\n"
      "        if(p==='setIcon'&&wrappedIcon)return wrappedIcon;\n"
      "        const v=Reflect.get(target,p,target);\n"
      "        return typeof v==='function'?v.bind(target):v;\n"
      "      }});\n"
      "      Object.defineProperty(ns,propName,{value:actProxy,configurable:true,writable:true});\n"
      "    }catch(_){}\n"
      "  }else{try{act.__sxBadgePatched=true;}catch(_){}}\n"
      "};\n"
      "patchActionNs(chrome,'action');\n"
      "patchActionNs(chrome,'browserAction');\n"
      "if(typeof browser!=='undefined'&&browser&&browser!==chrome){patchActionNs(browser,'action');patchActionNs(browser,'browserAction');}\n"
      "let menuOrder=[],menuMap=new Map(),menuSeq=1,flushTimer=null,pollStarted=false;\n"
      "const clickListeners=new Set();\n"
      "const scheduleFlush=()=>{if(flushTimer)return;flushTimer=setTimeout(()=>{flushTimer=null;const arr=[];for(const id of menuOrder){const it=menuMap.get(id);if(it)arr.push(it);}postJSON('/menus',{extId:EXT_ID,items:arr});},60);};\n"
      "const dispatchMenuClick=async(ev)=>{\n"
      "  if(!ev||!ev.menuItemId)return;\n"
      "  let tab=sxActiveTab||lastActiveTab;\n"
      "  try{\n"
      "    if(origQuery){\n"
      "      const all=await new Promise((r)=>origQuery({},(t)=>r(Array.isArray(t)?t:[])));\n"
      "      const web=all.filter(isWebTab);\n"
      "      if(ev.pageUrl){const exact=web.find((t)=>t.url===ev.pageUrl);if(exact)tab=exact;}\n"
      "      if(!tab&&lastActiveTabId!==null){const m=web.find((t)=>t.id===lastActiveTabId);if(m)tab=m;}\n"
      "      if(!tab&&web.length>0){tab=web.find((t)=>t.active)||web[web.length-1];}\n"
      "    }\n"
      "  }catch(_){}\n"
      "  const itemMeta=menuMap.get(String(ev.menuItemId));\n"
      "  const info={menuItemId:ev.menuItemId,parentMenuItemId:itemMeta&&itemMeta.parentId?itemMeta.parentId:undefined,pageUrl:ev.pageUrl||(tab&&tab.url)||'',editable:false};\n"
      "  for(const fn of clickListeners){try{fn(info,tab);}catch(_){}}\n"
      "};\n"
      "const startEventPoll=()=>{\n"
      "  if(pollStarted||!EXT_ID)return;pollStarted=true;\n"
      "  fetch(BASE+'/active-tab?token='+TOK+'&key='+KEY).then((r)=>r.status===200?r.json():null).then((d)=>{\n"
      "    if(d&&typeof d.tabSeq==='number'){lastTabSeq=Math.max(lastTabSeq,d.tabSeq);applyNativeActiveTab(d.activeTabId,d.activeTabUrl,d.activeTabTitle);}\n"
      "  }).catch(()=>{});\n"
      "  (async()=>{\n"
      "    while(true){\n"
      "      try{\n"
      "        const resp=await fetch(BASE+'/events?token='+TOK+'&key='+KEY+'&extId='+encodeURIComponent(EXT_ID)+'&tabSeq='+lastTabSeq);\n"
      "        if(resp.status===200){\n"
      "          const data=await resp.json();\n"
      "          if(data&&typeof data.tabSeq==='number'&&data.tabSeq>lastTabSeq){\n"
      "            lastTabSeq=data.tabSeq;\n"
      "            applyNativeActiveTab(data.activeTabId,data.activeTabUrl,data.activeTabTitle);\n"
      "          }\n"
      "          if(data&&Array.isArray(data.clicks)){for(const c of data.clicks){dispatchMenuClick(c);}}\n"
      "        }else if(resp.status===403||resp.status===404){return;}\n"
      "      }catch(_){await new Promise((r)=>setTimeout(r,2000));}\n"
      "    }\n"
      "  })();\n"
      "};\n"
      "const patchContextMenusNs=(ns)=>{\n"
      "  const cm=ns&&ns.contextMenus;\n"
      "  if(!cm||cm.__sxMenusPatched)return;\n"
      "  const origCreate=typeof cm.create==='function'?cm.create.bind(cm):null;\n"
      "  const origUpdate=typeof cm.update==='function'?cm.update.bind(cm):null;\n"
      "  const origRemove=typeof cm.remove==='function'?cm.remove.bind(cm):null;\n"
      "  const origRemoveAll=typeof cm.removeAll==='function'?cm.removeAll.bind(cm):null;\n"
      "  const wrappedCreate=origCreate?function(props,cb){\n"
      "    let retId;\n"
      "    try{retId=typeof cb==='function'?origCreate(props,cb):origCreate(props);}catch(e){throw e;}\n"
      "    try{\n"
      "      const p=props||{};\n"
      "      const id=String(p.id!=null?p.id:(retId!=null?retId:('sx_cm_'+(menuSeq++))));\n"
      "      const item={id,parentId:p.parentId!=null?String(p.parentId):null,title:p.title!=null?String(p.title):'',type:p.type||'normal',enabled:p.enabled!==false,checked:!!p.checked};\n"
      "      if(!menuMap.has(id))menuOrder.push(id);\n"
      "      menuMap.set(id,item);\n"
      "      scheduleFlush();\n"
      "    }catch(_){}\n"
      "    return retId;\n"
      "  }:null;\n"
      "  const wrappedUpdate=origUpdate?function(id,props,cb){\n"
      "    try{\n"
      "      const key=String(id),cur=menuMap.get(key);\n"
      "      if(cur&&props){\n"
      "        if(props.title!==undefined)cur.title=String(props.title);\n"
      "        if(props.type!==undefined)cur.type=String(props.type);\n"
      "        if(props.enabled!==undefined)cur.enabled=!!props.enabled;\n"
      "        if(props.checked!==undefined)cur.checked=!!props.checked;\n"
      "        if(props.parentId!==undefined)cur.parentId=props.parentId!=null?String(props.parentId):null;\n"
      "        scheduleFlush();\n"
      "      }\n"
      "    }catch(_){}\n"
      "    return typeof cb==='function'?origUpdate(id,props,cb):origUpdate(id,props);\n"
      "  }:null;\n"
      "  const wrappedRemove=origRemove?function(id,cb){\n"
      "    try{const key=String(id);menuMap.delete(key);menuOrder=menuOrder.filter((x)=>x!==key);scheduleFlush();}catch(_){}\n"
      "    return typeof cb==='function'?origRemove(id,cb):origRemove(id);\n"
      "  }:null;\n"
      "  const wrappedRemoveAll=origRemoveAll?function(cb){\n"
      "    try{menuMap.clear();menuOrder=[];scheduleFlush();}catch(_){}\n"
      "    return typeof cb==='function'?origRemoveAll(cb):origRemoveAll();\n"
      "  }:null;\n"
      "  const rawOnClicked=cm.onClicked||null;\n"
      "  const origAdd=(rawOnClicked&&typeof rawOnClicked.addListener==='function')?rawOnClicked.addListener.bind(rawOnClicked):null;\n"
      "  const origRem=(rawOnClicked&&typeof rawOnClicked.removeListener==='function')?rawOnClicked.removeListener.bind(rawOnClicked):null;\n"
      "  const wrappedAdd=origAdd?function(fn){if(typeof fn==='function')clickListeners.add(fn);return origAdd(fn);}:null;\n"
      "  const wrappedRem=origRem?function(fn){clickListeners.delete(fn);return origRem(fn);}:null;\n"
      "  let directOk=true;\n"
      "  if(wrappedCreate){try{Object.defineProperty(cm,'create',{value:wrappedCreate,configurable:true,writable:true});}catch(_){try{cm.create=wrappedCreate;}catch(_2){}} if(cm.create!==wrappedCreate)directOk=false;}\n"
      "  if(wrappedUpdate){try{Object.defineProperty(cm,'update',{value:wrappedUpdate,configurable:true,writable:true});}catch(_){try{cm.update=wrappedUpdate;}catch(_2){}} if(cm.update!==wrappedUpdate)directOk=false;}\n"
      "  if(wrappedRemove){try{Object.defineProperty(cm,'remove',{value:wrappedRemove,configurable:true,writable:true});}catch(_){try{cm.remove=wrappedRemove;}catch(_2){}} if(cm.remove!==wrappedRemove)directOk=false;}\n"
      "  if(wrappedRemoveAll){try{Object.defineProperty(cm,'removeAll',{value:wrappedRemoveAll,configurable:true,writable:true});}catch(_){try{cm.removeAll=wrappedRemoveAll;}catch(_2){}} if(cm.removeAll!==wrappedRemoveAll)directOk=false;}\n"
      "  let onClickedOk=true;\n"
      "  if(rawOnClicked&&wrappedAdd){try{Object.defineProperty(rawOnClicked,'addListener',{value:wrappedAdd,configurable:true,writable:true});}catch(_){try{rawOnClicked.addListener=wrappedAdd;}catch(_2){}} if(rawOnClicked.addListener!==wrappedAdd)onClickedOk=false;}\n"
      "  if(rawOnClicked&&wrappedRem){try{Object.defineProperty(rawOnClicked,'removeListener',{value:wrappedRem,configurable:true,writable:true});}catch(_){try{rawOnClicked.removeListener=wrappedRem;}catch(_2){}} if(rawOnClicked.removeListener!==wrappedRem)onClickedOk=false;}\n"
      "  if(!directOk||!onClickedOk){\n"
      "    try{\n"
      "      const onClickedProxy=rawOnClicked?new Proxy(rawOnClicked,{get(target,p){\n"
      "        if(p==='addListener'&&wrappedAdd)return wrappedAdd;\n"
      "        if(p==='removeListener'&&wrappedRem)return wrappedRem;\n"
      "        const v=Reflect.get(target,p,target);\n"
      "        return typeof v==='function'?v.bind(target):v;\n"
      "      }}):null;\n"
      "      const cmProxy=new Proxy(cm,{get(target,p){\n"
      "        if(p==='__sxMenusPatched')return true;\n"
      "        if(p==='create'&&wrappedCreate)return wrappedCreate;\n"
      "        if(p==='update'&&wrappedUpdate)return wrappedUpdate;\n"
      "        if(p==='remove'&&wrappedRemove)return wrappedRemove;\n"
      "        if(p==='removeAll'&&wrappedRemoveAll)return wrappedRemoveAll;\n"
      "        if(p==='onClicked'&&onClickedProxy)return onClickedProxy;\n"
      "        const v=Reflect.get(target,p,target);\n"
      "        return typeof v==='function'?v.bind(target):v;\n"
      "      }});\n"
      "      Object.defineProperty(ns,'contextMenus',{value:cmProxy,configurable:true,writable:true});\n"
      "    }catch(_){}\n"
      "  }else{try{cm.__sxMenusPatched=true;}catch(_){}}\n"
      "};\n"
      "patchContextMenusNs(chrome);\n"
      "if(typeof browser!=='undefined'&&browser&&browser!==chrome)patchContextMenusNs(browser);\n"
      // Safarium tabs belong to no Chrome window (windowId -1) and extension popouts are native windows that
      // chrome.tabs/windows cannot see. Stand in for both: windows.get(-1)/getCurrent/getLastFocused answer with
      // the Safarium window; the extension's popouts appear in tabs.query (ids from POP_BASE) and windows.remove /
      // update({focused}) / tabs.remove on them close or focus the native window (Bitwarden pop-out flows).
      // Popout ids are negative (POP_BASE - windowNumber): Chromium tab ids here run past 1.5e9, so a positive
      // range collided with real tabs (V11 broke tabs.get for every tab and Bitwarden's script injection with it).
      "const POP_BASE=-1000000000;\n"
      "const isPopId=(id)=>typeof id==='number'&&id<=POP_BASE;\n"
      "const popNo=(id)=>POP_BASE-id;\n"
      "const fetchPopouts=()=>fetch(BASE+'/popouts?token='+TOK+'&key='+KEY+'&extId='+encodeURIComponent(EXT_ID)).then(r=>r.json()).then(j=>Array.isArray(j&&j.popouts)?j.popouts:[]).catch(()=>[]);\n"
      "const popoutAction=(id,action)=>fetch(BASE+'/popout-action?token='+TOK+'&key='+KEY,{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:JSON.stringify({extId:EXT_ID,id:id,action:action})}).catch(()=>{});\n"
      "const urlMatches=(pattern,url)=>{if(!pattern)return true;return [].concat(pattern).some((pt)=>{pt=String(pt);const i=pt.indexOf('*');return i<0?pt===url:url.startsWith(pt.slice(0,i));});};\n"
      "const popTab=(p)=>({id:POP_BASE-p.id,windowId:POP_BASE-p.id,index:0,url:p.url,title:'',active:true,highlighted:true,selected:true,pinned:false,audible:false,discarded:false,autoDiscardable:true,incognito:false,status:'complete',groupId:-1});\n"
      "const popWin=(id,info)=>({id:id,focused:true,alwaysOnTop:false,incognito:false,type:'popup',state:'normal',left:0,top:0,width:380,height:630,tabs:(info&&info.populate)?[]:undefined});\n"
      "const settle=(p,cb)=>{if(typeof cb==='function'){p.then((v)=>cb(v),()=>cb(undefined));return;}return p;};\n"
      "const patchWindowsNs=(ns)=>{\n"
      "  const w=ns&&ns.windows;if(!w||w.__sxWinPatched)return;\n"
      "  const CUR=typeof w.WINDOW_ID_CURRENT==='number'?w.WINDOW_ID_CURRENT:-2;\n"
      "  const synth=(info)=>{const sw=(globalThis.screen&&screen.availWidth)||1440,sh=(globalThis.screen&&screen.availHeight)||900;\n"
      "    const width=Math.min(1200,sw),height=Math.min(800,sh);\n"
      "    const win={id:-1,focused:true,alwaysOnTop:false,incognito:false,type:'normal',state:'normal',left:Math.max(0,Math.round((sw-width)/2)),top:Math.max(0,Math.round((sh-height)/2)),width:width,height:height};\n"
      "    if(info&&info.populate){const t=lastRealTab||sxActiveTab;win.tabs=t?[Object.assign({},t,{windowId:-1,active:true})]:[];}\n"
      "    return win;};\n"
      "  const call=(fn,args)=>new Promise((resolve,reject)=>{try{fn.call(w,...args,(res)=>{const err=chrome.runtime&&chrome.runtime.lastError;if(err)reject(new Error(err.message));else resolve(res);});}catch(e){reject(e);}});\n"
      "  const split=(args)=>{const a=args.slice();const cb=typeof a[a.length-1]==='function'?a.pop():null;return [a,cb];};\n"
      "  const get=function(...args){const [a,cb]=split(args);const info=a.find((x)=>x&&typeof x==='object')||null;\n"
      "    if(isPopId(a[0]))return settle(Promise.resolve(popWin(a[0],info)),cb);\n"
      "    return settle(call(w.get,a).catch((e)=>{if(a[0]===-1||a[0]===CUR)return synth(info);throw e;}),cb);};\n"
      "  const cur=function(...args){const [a,cb]=split(args);const info=a.find((x)=>x&&typeof x==='object')||null;return settle(call(w.getCurrent,a).catch(()=>synth(info)),cb);};\n"
      "  const last=function(...args){const [a,cb]=split(args);const info=a.find((x)=>x&&typeof x==='object')||null;return settle(call(w.getLastFocused,a).catch(()=>synth(info)),cb);};\n"
      "  const all=function(...args){const [a,cb]=split(args);const info=a.find((x)=>x&&typeof x==='object')||null;return settle(call(w.getAll,a).catch(()=>[]).then((list)=>Array.isArray(list)&&list.length?list:[synth(info)]),cb);};\n"
      "  const remove=function(...args){const [a,cb]=split(args);if(isPopId(a[0])){popoutAction(popNo(a[0]),'close');return settle(Promise.resolve(),cb);}return settle(call(w.remove,a),cb);};\n"
      "  const update=function(...args){const [a,cb]=split(args);if(isPopId(a[0])){if(a[1]&&a[1].focused)popoutAction(popNo(a[0]),'focus');return settle(Promise.resolve(popWin(a[0],null)),cb);}return settle(call(w.update,a),cb);};\n"
      "  const map={get:get,getCurrent:cur,getLastFocused:last,getAll:all,remove:remove,update:update};\n"
      "  const prox=new Proxy(w,{get(target,p){if(p==='__sxWinPatched')return true;if(Object.prototype.hasOwnProperty.call(map,p))return map[p];const v=Reflect.get(target,p,target);return typeof v==='function'?v.bind(target):v;}});\n"
      "  try{Object.defineProperty(ns,'windows',{value:prox,configurable:true,writable:true});}catch(_){}\n"
      "};\n"
      "const patchPopoutTabs=(ns)=>{\n"
      "  const t=ns&&ns.tabs;if(!t||t.__sxPopTabs)return;\n"
      "  const oq=t.query,orm=t.remove,og=t.get;\n"
      "  const viaCb=(fn,args)=>new Promise((resolve,reject)=>{try{fn.call(t,...args,(res)=>{const err=chrome.runtime&&chrome.runtime.lastError;if(err)reject(new Error(err.message));else resolve(res);});}catch(e){reject(e);}});\n"
      "  const query=function(info,cb){const qi=info&&typeof info==='object'?info:{};\n"
      "    const p=viaCb(oq,[qi]).catch(()=>[]).then((tabs)=>{tabs=Array.isArray(tabs)?tabs:[];\n"
      "      const wantsOwnPages=qi.url&&[].concat(qi.url).some((u)=>String(u).startsWith('chrome-extension://'+EXT_ID+'/'));\n"
      "      if(!wantsOwnPages)return tabs;\n"
      "      return fetchPopouts().then((ps)=>tabs.concat(ps.filter((x)=>urlMatches(qi.url,x.url)).map(popTab)));});\n"
      "    return settle(p,cb);};\n"
      "  const remove=function(ids,cb){const arr=[].concat(ids);arr.filter(isPopId).forEach((i)=>popoutAction(popNo(i),'close'));\n"
      "    const rest=arr.filter((i)=>!isPopId(i));const p=rest.length?viaCb(orm,[rest.length===1?rest[0]:rest]):Promise.resolve();return settle(p,cb);};\n"
      "  const get=function(id,cb){if(isPopId(id))return settle(fetchPopouts().then((ps)=>{const m=ps.find((x)=>POP_BASE-x.id===id);if(!m)throw new Error('No tab with id: '+id);return popTab(m);}),cb);return settle(viaCb(og,[id]),cb);};\n"
      "  const map={query:query,remove:remove,get:get};\n"
      "  const prox=new Proxy(t,{get(target,p){if(p==='__sxPopTabs')return true;if(Object.prototype.hasOwnProperty.call(map,p))return map[p];const v=Reflect.get(target,p,target);return typeof v==='function'?v.bind(target):v;}});\n"
      "  try{Object.defineProperty(ns,'tabs',{value:prox,configurable:true,writable:true});}catch(_){}\n"
      "};\n"
      "patchWindowsNs(chrome);\n"
      "patchPopoutTabs(chrome);\n"
      "if(typeof browser!=='undefined'&&browser&&browser!==chrome){patchWindowsNs(browser);patchPopoutTabs(browser);}\n"
      "startEventPoll();\n"
      "setTimeout(syncAllBadges,800);\n"
      "setInterval(syncAllBadges,3000);\n"
      "}catch(_){}})();\n"
      "%@\n", startMarker, baseURL, tokStr, keyStr, endMarker];

  NSString *finalContent = [bridgeBlock stringByAppendingString:cleanBody];
  if (![finalContent isEqualToString:swContent]) {
    [finalContent writeToFile:swAbsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
  }
  return NO;
}

- (void)loadUnpackedExtensionAtPath:(NSString *)directoryPath
                         completion:(nullable void (^)(SXExtensionItem * _Nullable, NSError * _Nullable))completion {
  NSString *norm = [directoryPath stringByStandardizingPath];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:[norm stringByAppendingPathComponent:@"manifest.json"]]) {
    NSError *err = [NSError errorWithDomain:@"com.safarium.Extensions"
                                       code:2010
                                   userInfo:@{NSLocalizedDescriptionKey : @"Selected folder does not contain manifest.json"}];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
    }
    return;
  }

  // Copy unpacked extension into persistent SafariumExtensions storage so it survives even if source moves.
  NSString *slug = SXChromiumIDFromPath(norm);
  NSString *destDir = [self.extensionsRootDir
      stringByAppendingPathComponent:[NSString stringWithFormat:@"unpacked-%@", slug]];
  if (![norm hasPrefix:self.extensionsRootDir]) {
    [fm removeItemAtPath:destDir error:nil];
    NSError *cpErr = nil;
    if (![fm copyItemAtPath:norm toPath:destDir error:&cpErr]) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cpErr); });
      }
      return;
    }
  } else {
    destDir = norm;
  }

  [self hotLoadDirectoryIntoChromium:destDir storeID:nil completion:completion];
}

- (void)installExtensionFromCRXAtPath:(NSString *)crxPath
                           completion:(nullable void (^)(SXExtensionItem * _Nullable, NSError * _Nullable))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *readErr = nil;
    NSData *raw = [NSData dataWithContentsOfFile:crxPath options:0 error:&readErr];
    if (!raw) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, readErr); });
      }
      return;
    }
    NSData *pubKey = nil;
    NSError *zipErr = nil;
    NSData *zip = SXExtractZipFromCRXData(raw, nil, &pubKey, &zipErr);
    if (!zip) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, zipErr); });
      }
      return;
    }
    NSString *derivedID = pubKey.length > 0
                              ? SXChromiumIDFromBytes(pubKey.bytes, pubKey.length)
                              : SXChromiumIDFromBytes(zip.bytes, MIN(zip.length, (NSUInteger)4096));
    NSString *destDir = [self.extensionsRootDir
        stringByAppendingPathComponent:[NSString stringWithFormat:@"crx-%@", derivedID]];
    NSError *unpackErr = nil;
    if (!SXUnpackZipDataToDirectory(zip, destDir, &unpackErr)) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, unpackErr); });
      }
      return;
    }
    [self injectPublicKeyIfMissing:pubKey intoDirectory:destDir];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self hotLoadDirectoryIntoChromium:destDir
                                 storeID:(pubKey.length > 0 ? derivedID : nil)
                              completion:completion];
    });
  });
}

- (void)installExtensionFromChromeWebStoreID:(NSString *)storeID
                                  completion:(nullable void (^)(SXExtensionItem * _Nullable, NSError * _Nullable))completion {
  NSString *cleanID = [[storeID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
      lowercaseString];
  BOOL validID = (cleanID.length == 32);
  if (validID) {
    for (NSUInteger i = 0; i < 32; ++i) {
      unichar c = [cleanID characterAtIndex:i];
      if (c < 'a' || c > 'p') {
        validID = NO;
        break;
      }
    }
  }
  if (!validID) {
    NSError *err = [NSError errorWithDomain:@"com.safarium.Extensions"
                                       code:2020
                                   userInfo:@{NSLocalizedDescriptionKey : @"Invalid Chrome Web Store extension ID"}];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
    }
    return;
  }

  [self.inFlightStoreIDs addObject:cleanID];
  void (^finish)(SXExtensionItem * _Nullable, NSError * _Nullable) =
      ^(SXExtensionItem * _Nullable item, NSError * _Nullable err) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self.inFlightStoreIDs removeObject:cleanID];
          [self broadcastCWSStateForStoreID:cleanID installed:(item != nil && err == nil)];
          if (completion) {
            completion(item, err);
          }
        });
      };

  NSString *chromeVer = [NSString stringWithFormat:@"%d.%d.%d.%d",
                                                   CHROME_VERSION_MAJOR,
                                                   CHROME_VERSION_MINOR,
                                                   CHROME_VERSION_BUILD,
                                                   CHROME_VERSION_PATCH];
  NSString *urlStr = [NSString
      stringWithFormat:@"https://clients2.google.com/service/update2/crx?"
                       @"response=redirect&prodversion=%@&acceptformat=crx2,crx3&x=id%%3D%@%%26uc",
                       chromeVer, cleanID];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
  [req setValue:[SXEngineRuntime sharedRuntime].userAgent forHTTPHeaderField:@"User-Agent"];
  [req setValue:@"application/x-chrome-extension,*/*" forHTTPHeaderField:@"Accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData * _Nullable data,
                            NSURLResponse * _Nullable response,
                            NSError * _Nullable error) {
          if (error || !data || data.length < 64) {
            NSError *failErr = error ?: [NSError errorWithDomain:@"com.safarium.Extensions"
                                                            code:2021
                                                        userInfo:@{NSLocalizedDescriptionKey :
                                                                       @"Chrome Web Store CRX download failed"}];
            finish(nil, failErr);
            return;
          }
          if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            if (status < 200 || status >= 300) {
              NSError *httpErr = [NSError errorWithDomain:@"com.safarium.Extensions"
                                                     code:status
                                                 userInfo:@{NSLocalizedDescriptionKey :
                                                                [NSString stringWithFormat:@"Chrome Web Store HTTP %ld",
                                                                                           (long)status]}];
              finish(nil, httpErr);
              return;
            }
          }

          NSData *pubKey = nil;
          NSError *zipErr = nil;
          NSData *zip = SXExtractZipFromCRXData(data, cleanID, &pubKey, &zipErr);
          if (!zip) {
            finish(nil, zipErr);
            return;
          }
          NSString *destDir = [self.extensionsRootDir
              stringByAppendingPathComponent:[NSString stringWithFormat:@"cws-%@", cleanID]];
          NSError *unpackErr = nil;
          if (!SXUnpackZipDataToDirectory(zip, destDir, &unpackErr)) {
            finish(nil, unpackErr);
            return;
          }
          if (getenv("SAFARIUM_CEF_DEBUG")) {
            fprintf(stderr, "[ExtMgr] CWS downloaded & unpacked %s -> %s (%lu bytes)\n",
                    cleanID.UTF8String, destDir.UTF8String, (unsigned long)data.length);
            fflush(stderr);
          }
          [self injectPublicKeyIfMissing:pubKey intoDirectory:destDir];
          dispatch_async(dispatch_get_main_queue(), ^{
            [self hotLoadDirectoryIntoChromium:destDir storeID:cleanID completion:finish];
          });
        }];
  [task resume];
}

- (void)uninstallExtensionWithID:(NSString *)extensionID
                      completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  NSString *lower = [extensionID lowercaseString];
  NSMutableDictionary *target = nil;
  for (NSMutableDictionary *entry in self.registryEntries) {
    NSString *eid = [(NSString *)entry[@"extensionID"] lowercaseString];
    NSString *sid = [(NSString *)entry[@"storeID"] lowercaseString];
    if ([eid isEqualToString:lower] || (sid.length > 0 && [sid isEqualToString:lower])) {
      target = entry;
      break;
    }
  }
  if (!target) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil); });
    }
    return;
  }

  NSString *runtimeID = target[@"extensionID"];
  NSString *storeID = target[@"storeID"];
  NSString *installPath = target[@"path"];
  [self closePopupForExtensionID:runtimeID];
  [self.nativelyLoadedIDs removeObject:[runtimeID lowercaseString]];
  [self.registryEntries removeObject:target];
  [self saveRegistryToDisk];

  if (installPath.length > 0 && [installPath hasPrefix:self.extensionsRootDir]) {
    [[NSFileManager defaultManager] removeItemAtPath:installPath error:nil];
  }

  // Notify SafariShell toolbar & CWS tabs immediately so the removed extension icon
  // disappears without waiting for the hidden chrome://extensions admin browser to boot.
  [self removeInjectedCSSForExtensionID:runtimeID];
  [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
  [self broadcastCWSStateForStoreID:(storeID ?: runtimeID) installed:NO];

  _liveLoader->Uninstall(
      runtimeID.UTF8String,
      [self, runtimeID, storeID, completion](bool success, const std::string& removedId) {
        (void)success;
        (void)removedId;
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
          [self broadcastCWSStateForStoreID:(storeID ?: runtimeID) installed:NO];
          if (completion) {
            completion(YES, nil);
          }
        });
      });
}

- (nullable NSMutableDictionary *)registryEntryForID:(NSString *)extensionID {
  if (!extensionID.length) return nil;
  NSString *lower = [extensionID lowercaseString];
  for (NSMutableDictionary *entry in self.registryEntries) {
    NSString *eid = [(NSString *)entry[@"extensionID"] lowercaseString];
    NSString *sid = [(NSString *)entry[@"storeID"] lowercaseString];
    if ([eid isEqualToString:lower] || (sid.length > 0 && [sid isEqualToString:lower])) {
      return entry;
    }
  }
  return nil;
}

- (void)setExtensionWithID:(NSString *)extensionID
                   enabled:(BOOL)enabled
                completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  NSMutableDictionary *target = [self registryEntryForID:extensionID];
  if (!target) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil); });
    }
    return;
  }

  NSString *runtimeID = target[@"extensionID"];
  NSString *installPath = target[@"path"];
  target[@"enabled"] = @(enabled);
  [self saveRegistryToDisk];

  if (!enabled) {
    [self closePopupForExtensionID:runtimeID];
    [self removeInjectedCSSForExtensionID:runtimeID];
  }

  [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];

  BOOL loadedNatively = [self.nativelyLoadedIDs containsObject:[runtimeID lowercaseString]];
  if (enabled && !loadedNatively && installPath.length > 0) {
    [self ensureServiceWorkerBridgeInDirectory:installPath];
    _liveLoader->LoadUnpacked(
        installPath.UTF8String,
        [self, runtimeID, installPath, completion](bool success, const std::string& loadedId) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (success && loadedId.size() == 32) {
              NSString *lid = [NSString stringWithUTF8String:loadedId.c_str()];
              [self.nativelyLoadedIDs addObject:[lid lowercaseString]];
            } else {
              [self.nativelyLoadedIDs addObject:[runtimeID lowercaseString]];
            }
            [self injectManifestContentScriptsForExtensionID:runtimeID directory:installPath];
            [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
            if (completion) completion(YES, nil);
          });
        });
    return;
  }

  _liveLoader->SetEnabled(
      runtimeID.UTF8String, enabled ? true : false,
      [self, runtimeID, installPath, enabled, completion](bool success, const std::string& updatedId) {
        (void)success;
        (void)updatedId;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (enabled && installPath.length > 0) {
            [self injectManifestContentScriptsForExtensionID:runtimeID directory:installPath];
          }
          [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
          if (completion) completion(YES, nil);
        });
      });
}

- (void)setExtensionWithID:(NSString *)extensionID
            allowInPrivate:(BOOL)allowInPrivate
                completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  NSMutableDictionary *target = [self registryEntryForID:extensionID];
  if (!target) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil); });
    }
    return;
  }

  NSString *runtimeID = target[@"extensionID"];
  target[@"allowInPrivate"] = @(allowInPrivate);
  [self saveRegistryToDisk];
  [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];

  _liveLoader->SetIncognitoAccess(
      runtimeID.UTF8String, allowInPrivate ? true : false,
      [self, completion](bool success, const std::string& updatedId) {
        (void)success;
        (void)updatedId;
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] notifyExtensionsUpdated];
          if (completion) completion(YES, nil);
        });
      });
}

- (void)clearStorageForExtensionWithID:(NSString *)extensionID
                            completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  NSMutableDictionary *target = [self registryEntryForID:extensionID];
  if (!target) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil); });
    }
    return;
  }

  NSString *runtimeID = target[@"extensionID"];
  [self closePopupForExtensionID:runtimeID];

  NSString *profileDir = [self.extensionsRootDir stringByDeletingLastPathComponent];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray<NSString *> *subRoots = @[
    profileDir,
    [profileDir stringByAppendingPathComponent:@"Default"]
  ];
  for (NSString *root in subRoots) {
    NSArray<NSString *> *targets = @[
      [[root stringByAppendingPathComponent:@"Local Extension Settings"] stringByAppendingPathComponent:runtimeID],
      [[root stringByAppendingPathComponent:@"Sync Extension Settings"] stringByAppendingPathComponent:runtimeID],
      [[root stringByAppendingPathComponent:@"Managed Extension Settings"] stringByAppendingPathComponent:runtimeID],
      [[root stringByAppendingPathComponent:@"IndexedDB"]
          stringByAppendingPathComponent:[NSString stringWithFormat:@"chrome-extension_%@_0.indexeddb.leveldb", runtimeID]],
      [[root stringByAppendingPathComponent:@"IndexedDB"]
          stringByAppendingPathComponent:[NSString stringWithFormat:@"chrome-extension_%@_0.indexeddb.blob", runtimeID]],
    ];
    for (NSString *p in targets) {
      if ([fm fileExistsAtPath:p]) {
        [fm removeItemAtPath:p error:nil];
      }
    }
  }

  _liveLoader->Reload(
      runtimeID.UTF8String,
      [completion](bool success, const std::string& reloadedId) {
        (void)success;
        (void)reloadedId;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (completion) completion(YES, nil);
        });
      });
}

- (int)resolvedRealTabIdForTab:(nullable SXBrowserTab *)tab {
  if (tab.currentURL) {
    std::string normURL, host;
    if (SXExtractNormalizedBadgeURL(tab.currentURL, &normURL, &host)) {
      std::lock_guard<std::mutex> lock(_bridgeMutex);
      auto uit = _realTabIdByNormURL.find(normURL);
      if (uit != _realTabIdByNormURL.end() && uit->second > 0) {
        return uit->second;
      }
      auto hit = _realTabIdByHost.find(host);
      if (hit != _realTabIdByHost.end() && hit->second > 0) {
        return hit->second;
      }
      if (_lastRealWebTabId > 0) {
        return _lastRealWebTabId;
      }
    }
  }
  return tab ? [tab chromiumBrowserIdentifier] : 1;
}

- (nullable NSView *)createPopupViewForExtensionID:(NSString *)extensionID
                                             width:(CGFloat)width
                                            height:(CGFloat)height
                                        parentView:(nullable NSView *)parentView {
  SXExtensionItem *item = [self extensionWithIDOrStoreID:extensionID];
  if (!item || !item.popupURL) {
    return nil;
  }

  [self closePopupForExtensionID:item.extensionID];

  CGFloat w = MAX(240.0, width > 0 ? width : 380.0);
  CGFloat h = MAX(120.0, height > 0 ? height : 520.0);
  SXExtensionPopupView *popupView = [[SXExtensionPopupView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
  popupView.extensionID = item.extensionID;
  popupView.wantsLayer = YES;
  popupView.layer.opaque = NO;
  popupView.layer.backgroundColor = NSColor.clearColor.CGColor;
  popupView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  if (parentView) {
    popupView.frame = parentView.bounds.size.width > 1 ? parentView.bounds : NSMakeRect(0, 0, w, h);
    [parentView addSubview:popupView];
  }

  CGFloat initW = popupView.bounds.size.width > 1 ? popupView.bounds.size.width : w;
  CGFloat initH = popupView.bounds.size.height > 1 ? popupView.bounds.size.height : h;
  CefRefPtr<SXExtensionPopupClient> client =
      new SXExtensionPopupClient(popupView, item.extensionID, initW, initH);
  popupView->_popupClient = client;
  self.activePopups[item.extensionID] = popupView;

  CefWindowInfo windowInfo;
  CefRect bounds(0, 0, (int)std::round(initW), (int)std::round(initH));
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(popupView), bounds);

  CefBrowserSettings browserSettings;
  browserSettings.background_color = CefColorSetARGB(0x00, 0x00, 0x00, 0x00);

  // Pass the currently active SXBrowserTab's real URL, title, tab ID, and host window frame into the
  // popup renderer so `chrome.tabs.query` and `chrome.windows.getCurrent` work natively (e.g. Bitwarden popout).
  SXBrowserTab *activeTab = SXFindActiveVisibleTab();
  NSWindow *hostWin = activeTab.contentView.window ?: NSApp.mainWindow ?: NSApp.keyWindow;
  NSRect hostFrame = hostWin ? hostWin.frame : NSMakeRect(120, 80, 1200, 800);
  NSScreen *primaryScreen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
  CGFloat primaryH = primaryScreen ? primaryScreen.frame.size.height : 900.0;
  int chromeLeft = (int)std::round(hostFrame.origin.x);
  int chromeTop = (int)std::round(MAX(0.0, primaryH - NSMaxY(hostFrame)));
  int chromeW = (int)std::round(MAX(320.0, hostFrame.size.width));
  int chromeH = (int)std::round(MAX(320.0, hostFrame.size.height));

  CefRefPtr<CefDictionaryValue> extraInfo = CefDictionaryValue::Create();
  extraInfo->SetBool("sx_is_ext_popup", true);
  extraInfo->SetBool("sx_is_ext_popout", false);
  extraInfo->SetString("sx_ext_id", CefString(item.extensionID.UTF8String));
  extraInfo->SetString("sx_active_tab_url",
                       CefString((activeTab.currentURL.absoluteString ?: @"about:blank").UTF8String));
  extraInfo->SetString("sx_active_tab_title",
                       CefString((activeTab.title ?: @"").UTF8String));
  extraInfo->SetInt("sx_active_tab_id", activeTab ? [activeTab chromiumBrowserIdentifier] : 1);
  extraInfo->SetBool("sx_active_tab_loading", activeTab.isLoading ? true : false);
  extraInfo->SetInt("sx_host_win_left", chromeLeft);
  extraInfo->SetInt("sx_host_win_top", chromeTop);
  extraInfo->SetInt("sx_host_win_width", chromeW);
  extraInfo->SetInt("sx_host_win_height", chromeH);

  // Always load the genuine `chrome-extension://<id>/...` origin inside Chromium's real
  // ExtensionSystem so MV3 background service workers, chrome.runtime, and chrome.storage work!
  CefBrowserHost::CreateBrowser(windowInfo, client,
                                CefString(item.popupURL.absoluteString.UTF8String),
                                browserSettings, extraInfo, nullptr);
  return popupView;
}

- (void)openPopoutWindowForExtensionID:(NSString *)extensionID
                                   url:(NSURL *)url
                                 width:(CGFloat)width
                                height:(CGFloat)height
                                  left:(CGFloat)left
                                   top:(CGFloat)top {
  if (!url) return;
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self openPopoutWindowForExtensionID:extensionID
                                       url:url
                                     width:width
                                    height:height
                                      left:left
                                       top:top];
    });
    return;
  }

  SXExtensionItem *item = [self extensionWithIDOrStoreID:extensionID];
  NSString *extID = item.extensionID ?: extensionID ?: @"";
  NSString *winTitle = item.name.length > 0 ? item.name : @"Extension";

  CGFloat w = MAX(320.0, MIN(960.0, width > 0 ? width : 380.0));
  CGFloat h = MAX(360.0, MIN(960.0, height > 0 ? height : 630.0));

  NSScreen *primaryScreen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
  CGFloat primaryH = primaryScreen ? primaryScreen.frame.size.height : 900.0;
  NSRect visFrame = (NSApp.mainWindow.screen ?: NSScreen.mainScreen ?: primaryScreen).visibleFrame;
  if (visFrame.size.width < 100 || visFrame.size.height < 100) {
    visFrame = NSMakeRect(0, 0, 1440, 900);
  }

  NSWindow *refWin = NSApp.mainWindow ?: NSApp.keyWindow;
  CGFloat originX = 0.0;
  CGFloat originY = 0.0;
  if (left >= 0.0 && top >= 0.0) {
    originX = left;
    originY = primaryH - top - h;
  } else if (refWin) {
    originX = NSMaxX(refWin.frame) - w - 18.0;
    originY = NSMaxY(refWin.frame) - h - 78.0;
  } else {
    originX = NSMidX(visFrame) - w * 0.5;
    originY = NSMidY(visFrame) - h * 0.5;
  }
  originX = MAX(visFrame.origin.x + 12.0, MIN(NSMaxX(visFrame) - w - 12.0, originX));
  originY = MAX(visFrame.origin.y + 12.0, MIN(NSMaxY(visFrame) - h - 12.0, originY));

  NSWindowStyleMask style = NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable;
  NSWindow *popoutWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(originX, originY, w, h)
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
  popoutWin.title = winTitle;
  popoutWin.releasedWhenClosed = NO;
  popoutWin.minSize = NSMakeSize(300.0, 320.0);
  popoutWin.delegate = self;

  SXExtensionPopupView *popupView = [[SXExtensionPopupView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
  popupView.extensionID = extID;
  popupView.wantsLayer = YES;
  popupView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  popoutWin.contentView = popupView;

  CefRefPtr<SXExtensionPopupClient> client =
      new SXExtensionPopupClient(popupView, extID, w, h, YES);
  popupView->_popupClient = client;

  [self.popoutWindows addObject:popoutWin];
  [self.popoutURLs setObject:(url.absoluteString ?: @"") forKey:popoutWin];

  CefWindowInfo windowInfo;
  CefRect bounds(0, 0, (int)std::round(w), (int)std::round(h));
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(popupView), bounds);

  CefBrowserSettings browserSettings;
  browserSettings.background_color = CefColorSetARGB(0xFF, 0xFF, 0xFF, 0xFF);

  SXBrowserTab *activeTab = SXFindActiveVisibleTab();
  NSRect hostFrame = popoutWin.frame;
  int chromeLeft = (int)std::round(hostFrame.origin.x);
  int chromeTop = (int)std::round(MAX(0.0, primaryH - NSMaxY(hostFrame)));

  CefRefPtr<CefDictionaryValue> extraInfo = CefDictionaryValue::Create();
  extraInfo->SetBool("sx_is_ext_popup", true);
  extraInfo->SetBool("sx_is_ext_popout", true);
  extraInfo->SetString("sx_ext_id", CefString(extID.UTF8String));
  extraInfo->SetString("sx_active_tab_url",
                       CefString((activeTab.currentURL.absoluteString ?: @"about:blank").UTF8String));
  extraInfo->SetString("sx_active_tab_title",
                       CefString((activeTab.title ?: @"").UTF8String));
  extraInfo->SetInt("sx_active_tab_id", [self resolvedRealTabIdForTab:activeTab]);
  extraInfo->SetBool("sx_active_tab_loading", activeTab.isLoading ? true : false);
  extraInfo->SetInt("sx_host_win_left", chromeLeft);
  extraInfo->SetInt("sx_host_win_top", chromeTop);
  extraInfo->SetInt("sx_host_win_width", (int)std::round(w));
  extraInfo->SetInt("sx_host_win_height", (int)std::round(h));

  CefBrowserHost::CreateBrowser(windowInfo, client,
                                CefString(url.absoluteString.UTF8String),
                                browserSettings, extraInfo, nullptr);

  [popoutWin makeKeyAndOrderFront:nil];
}

- (void)closePopoutWindow:(NSWindow *)window {
  if (!window) return;
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self closePopoutWindow:window];
    });
    return;
  }
  if ([window.contentView isKindOfClass:[SXExtensionPopupView class]]) {
    [(SXExtensionPopupView *)window.contentView closeEmbeddedBrowser];
  }
  window.delegate = nil;
  [self.popoutWindows removeObject:window];
  [window orderOut:nil];
  [window close];
}

- (void)closeAllPopoutWindows {
  for (NSWindow *win in [self.popoutWindows copy]) {
    [self closePopoutWindow:win];
  }
}

- (void)windowWillClose:(NSNotification *)notification {
  NSWindow *win = notification.object;
  if (![win isKindOfClass:[NSWindow class]]) return;
  if ([win.contentView isKindOfClass:[SXExtensionPopupView class]]) {
    [(SXExtensionPopupView *)win.contentView closeEmbeddedBrowser];
  }
  win.delegate = nil;
  [self.popoutWindows removeObject:win];
}

- (void)closePopupForExtensionID:(nullable NSString *)extensionID {
  if (!extensionID.length) {
    [self closeAllPopups];
    return;
  }
  SXExtensionPopupView *view = self.activePopups[extensionID];
  if (view) {
    [self.activePopups removeObjectForKey:extensionID];
    [view closeEmbeddedBrowser];
    [view removeFromSuperview];
  }
}

- (void)closeAllPopups {
  for (SXExtensionPopupView *view in [self.activePopups.allValues copy]) {
    [view closeEmbeddedBrowser];
    [view removeFromSuperview];
  }
  [self.activePopups removeAllObjects];
}

- (void)shutdown {
  [self stopBridgeServer];
  [self closeAllPopups];
  [self closeAllPopoutWindows];
  _liveBrowsers.clear();
  if (_liveLoader) {
    _liveLoader->Shutdown();
    for (int i = 0; i < 80 && _liveLoader->HasOpenBrowsers(); ++i) {
      CefDoMessageLoopWork();
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (!_liveLoader->HasOpenBrowsers()) {
      _liveLoader = nullptr;
    }
  }
}

@end
