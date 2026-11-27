// SXMediaTranscodeServer.h
// Same-origin CEF CefResourceHandler that transparently transcodes unsupported
// proprietary video streams (H.264/HEVC/AAC MP4/MOV) into open WebM (VP8 + Opus)
// with disk caching, HTTP 206 byte-range support, and AVFoundation duration probing.

#pragma once

#include "include/cef_request.h"
#include "include/cef_resource_handler.h"

#include <cstdint>
#include <string>

// Returns a CefResourceHandler if `request` carries `__sx_tc=1` or `__sx_meta=1`,
// otherwise returns nullptr so Chromium handles the request normally.
CefRefPtr<CefResourceHandler> CreateSXMediaResourceHandler(
    CefRefPtr<CefRequest> request);

// Legacy stub kept for SXApp compatibility (no background TCP socket needed).
class SXMediaTranscodeServer {
 public:
  static SXMediaTranscodeServer& Shared();
  bool Start() { return true; }
  uint16_t Port() const { return 0; }
  const std::string& Token() const { return token_; }
  bool IsRunning() const { return false; }

 private:
  SXMediaTranscodeServer() = default;
  std::string token_;
};
