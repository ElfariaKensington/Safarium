// SXApp.h
// Browser-process CefApp & CefBrowserProcessHandler for Safarium.

#pragma once

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"

class SXBrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  SXBrowserApp() = default;
  ~SXBrowserApp() override = default;

  // CefApp:
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  // CefBrowserProcessHandler:
  void OnContextInitialized() override;
  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override;
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;
  bool OnAlreadyRunningAppRelaunch(
      CefRefPtr<CefCommandLine> command_line,
      const CefString& current_directory) override;
  CefRefPtr<CefClient> GetDefaultClient() override;

 private:
  CefRefPtr<CefClient> default_client_;
  IMPLEMENT_REFCOUNTING(SXBrowserApp);
};
