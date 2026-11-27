import XCTest
import AppKit
@testable import Safarium

/// Touch ID on the Sign in with Apple sheet must only be offered when it can actually finish the sign-in.
final class AppleSignInGatingTests: HermeticTestCase {
    private final class CountingEvaluator: BiometricAuthEvaluating {
        var canEvaluateBiometricsOrWatch = true
        var canEvaluateDeviceOwnerAuth = true
        var calls = 0
        func makeEmbeddedAuthView(controlSize: NSControl.ControlSize) -> NSView? { nil }
        func evaluate(reason: String, allowPasswordFallback: Bool, completion: @escaping (BiometricEvaluationOutcome) -> Void) {
            calls += 1
            completion(.matched)
        }
        func invalidate() {}
    }

    nonisolated(unsafe) private var manager: ApplePasswordsPasskeyManager!
    nonisolated(unsafe) private var evaluator: CountingEvaluator!
    nonisolated(unsafe) private var tab: MockBrowserTab!
    nonisolated(unsafe) private var host: NSView!
    private let authorizeURL = URL(string: "https://appleid.apple.com/auth/authorize?client_id=com.janitorai.web&redirect_uri=https%3A%2F%2Fjanitorai.com%2Fcb&scope=name%20email")!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)) // manager holds it weakly
        manager = ApplePasswordsPasskeyManager(window: nil, webContentHost: host)
        if manager.vaultURL.path.hasPrefix(Self.sandboxRoot.path) {
            try? FileManager.default.removeItem(at: manager.vaultURL)
        }
        let ev = CountingEvaluator()
        evaluator = ev
        manager.biometricAuthenticatorFactory = { ev }
        manager.immediateDismissOnMatchForTesting = true
        tab = MockBrowserTab()
    }

    override func tearDown() {
        if let url = manager?.vaultURL, url.path.hasPrefix(Self.sandboxRoot.path) {
            try? FileManager.default.removeItem(at: url)
        }
        manager = nil
        host = nil
        super.tearDown()
    }

    private func pageState(_ step: String) {
        let json: [String: Any] = ["type": "apple_signin_page_state", "step": step, "url": authorizeURL.absoluteString]
        let data = try! JSONSerialization.data(withJSONObject: json)
        manager.handleAuthEventJSON(String(data: data, encoding: .utf8)!, tab: tab)
    }

    private var driveScripts: [String] { tab.recordedScripts.filter { $0.contains("__safariumDriveAppleSignIn") && $0.contains("continueOrSubmit") } }

    func testNoSavedAccountShowsApplePageInsteadOfTouchID() {
        XCTAssertTrue(manager.vaultURL.path.hasPrefix(Self.sandboxRoot.path))
        manager.handleTabURLChanged(url: authorizeURL, tab: tab)
        XCTAssertFalse(manager.hasActiveBiometricSheet, "no sheet flashes over Apple's page")
        XCTAssertEqual(evaluator.calls, 0, "no fingerprint scan before Apple says what it needs")

        pageState("credentials_needed")
        XCTAssertEqual(evaluator.calls, 0, "Touch ID cannot sign in without a saved Apple Account")
        XCTAssertFalse(manager.hasActiveBiometricSheet, "Apple's own sign-in page is handed to the user")
        XCTAssertTrue(driveScripts.isEmpty)
    }

    func testExistingAppleSessionUsesTouchIDForConsent() {
        manager.handleTabURLChanged(url: authorizeURL, tab: tab)
        pageState("loading")
        XCTAssertEqual(evaluator.calls, 0)
        XCTAssertFalse(manager.hasActiveBiometricSheet)
        pageState("consent_ready")
        XCTAssertEqual(evaluator.calls, 1)
        XCTAssertEqual(driveScripts.count, 1, "after Touch ID the consent Continue is clicked")
    }

    func testSavedAppleAccountScansImmediately() {
        guard manager.vaultURL.path.hasPrefix(Self.sandboxRoot.path) else { return XCTFail("vault outside sandbox") }
        seedVaultPassword(manager, host: "idmsa.apple.com", username: "someone@example.com", password: "test-only-value")
        manager.handleTabURLChanged(url: authorizeURL, tab: tab)
        XCTAssertEqual(evaluator.calls, 1)
        XCTAssertEqual(driveScripts.count, 1)
        XCTAssertTrue(driveScripts[0].contains("someone@example.com"))
    }
}

/// Writes a password entry straight into the local vault (Safarium no longer saves passwords itself; only the
/// Sign in with Apple flow still reads an existing Apple Account entry).
private func seedVaultPassword(_ manager: ApplePasswordsPasskeyManager, host: String, username: String, password: String) {
    var vault = manager.loadVault()
    vault.passwords.insert(.init(host: host.lowercased(), username: username, password: password), at: 0)
    manager.persistVault(vault)
}
