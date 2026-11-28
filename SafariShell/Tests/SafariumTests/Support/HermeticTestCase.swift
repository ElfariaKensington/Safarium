import XCTest
import AppKit
import CryptoKit
@testable import Safarium

/// Every test class in this target MUST inherit from `HermeticTestCase`.
///
/// Safarium persists history / bookmarks / favicons under `~/Library/...`. To make sure the suite never
/// reads or writes the real user profile, the first test to run redirects the Foundation home directory
/// (`CFFIXED_USER_HOME`) to a throw-away directory. `testSandboxGuard` (see SandboxGuardTests) fails the whole
/// run loudly if a test class bypasses this base class.
class HermeticTestCase: XCTestCase {
    static let sandboxRoot: URL = {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SafariumTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        for sub in ["Library/Application Support", "Library/Caches", "Downloads", "Desktop", "Documents"] {
            try? fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        setenv("CFFIXED_USER_HOME", root.path, 1)
        return root
    }()

    static func installSandbox() {
        _ = sandboxRoot
        MotionPreference.overrideForTesting = false
        // The vault key normally lives in the real login Keychain; tests must never touch it.
    }

    override class func setUp() {
        installSandbox()
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        Self.installSandbox()
        precondition(NSHomeDirectory().hasPrefix(Self.sandboxRoot.path), "tests must never touch the real home directory")
    }
}

/// Spin the main run loop (lets AppKit animations / async blocks run in tests).
@MainActor
func spinRunLoop(_ seconds: TimeInterval = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Weak reference holder used by leak tests.
final class WeakBox { weak var value: AnyObject?; init(_ v: AnyObject) { value = v } }
