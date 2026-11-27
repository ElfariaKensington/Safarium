import AppKit

@main
struct SafariumMain {
    static func main() {
        // Install Chromium CrAppProtocol hooks on NSApplication before running the event loop.
        ChromiumRuntimeBootstrap.installHooksIfAvailable()

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
