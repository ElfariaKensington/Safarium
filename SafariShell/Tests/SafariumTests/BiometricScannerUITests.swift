import XCTest
import AppKit
@testable import Safarium

/// Hermetic unit and layout tests for Safari's native biometric scanner widget (`SafariBiometricScannerView`),
/// modal authentication sheet (`SafariBiometricSheetView`), account monogram helpers, and Private Browsing lock overlay.
final class BiometricScannerUITests: HermeticTestCase {

    private final class StubEvaluator: BiometricAuthEvaluating {
        var canEvaluateBiometricsOrWatch: Bool = true
        var canEvaluateDeviceOwnerAuth: Bool = true
        var embeddedView: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
        var outcomes: [BiometricEvaluationOutcome] = [.matched]
        var calls: [(reason: String, fallback: Bool)] = []
        var invalidated: Int = 0

        func makeEmbeddedAuthView(controlSize: NSControl.ControlSize) -> NSView? {
            embeddedView
        }

        func evaluate(reason: String, allowPasswordFallback: Bool, completion: @escaping (BiometricEvaluationOutcome) -> Void) {
            calls.append((reason, allowPasswordFallback))
            let next = outcomes.isEmpty ? .matched : outcomes.removeFirst()
            completion(next)
        }

        func invalidate() {
            invalidated += 1
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testScannerStateTransitionsAndAccessibility() {
        let scanner = SafariBiometricScannerView(frame: NSRect(x: 0, y: 0, width: 240, height: 76))
        scanner.layoutSubtreeIfNeeded()
        XCTAssertEqual(scanner.state, .idle)
        XCTAssertEqual(scanner.accessibilityRole(), .button)
        XCTAssertEqual(scanner.accessibilityLabel(), "Continue with Touch ID")

        scanner.setState(.scanning, animated: false)
        XCTAssertEqual(scanner.state, .scanning)
        XCTAssertEqual(scanner.accessibilityLabel(), "Continue with Touch ID")

        scanner.setState(.failed("Mismatch"), animated: false)
        XCTAssertEqual(scanner.state, .failed("Mismatch"))
        XCTAssertTrue(scanner.accessibilityLabel()?.contains("Try Touch ID Again") == true)

        scanner.setState(.fallbackPassword, animated: false)
        XCTAssertEqual(scanner.state, .fallbackPassword)

        scanner.setState(.matched, animated: false)
        XCTAssertEqual(scanner.state, .matched)
        XCTAssertEqual(scanner.accessibilityLabel(), "Authenticated")

        var activations = 0
        scanner.onActivateScanner = { activations += 1 }
        XCTAssertTrue(scanner.accessibilityPerformPress())
        XCTAssertEqual(activations, 1)
    }

    func testInitialsAndDisplayNameNormalization() {
        XCTAssertEqual(SafariBiometricAccountOption.computeInitials(from: "Elfa Metesar"), "EM")
        XCTAssertEqual(SafariBiometricAccountOption.computeInitials(from: "ada.lovelace@analytical.test"), "AL")
        XCTAssertEqual(SafariBiometricAccountOption.computeInitials(from: "hopper"), "HO")
        XCTAssertEqual(SafariBiometricAccountOption.computeInitials(from: ""), "AA")

        XCTAssertEqual(
            ApplePasswordsPasskeyManager.cleanRelyingPartyDisplayName(rawName: "Welcome | JanitorAI", host: "janitorai.com"),
            "Janitor"
        )
        XCTAssertEqual(
            ApplePasswordsPasskeyManager.cleanRelyingPartyDisplayName(rawName: "Sign in — Linear", host: "linear.app"),
            "Linear"
        )
        XCTAssertEqual(
            ApplePasswordsPasskeyManager.cleanRelyingPartyDisplayName(rawName: nil, host: "", clientId: "com.figma.desktop"),
            "Figma"
        )
    }

    func testSignInWithAppleModalSheetAndInteractiveWebContainer() {
        let cfg = SafariBiometricSheetKind.SignInWithAppleConfig(
            siteDisplayName: "Janitor",
            siteHost: "janitorai.com",
            siteIcon: nil,
            accountName: "Elfa Metesar",
            accountSubtitle: "Your account",
            requestsEmailScope: true,
            hideMyEmailSelected: false
        )
        let sheet = SafariBiometricSheetView(kind: .signInWithApple(cfg))
        sheet.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        sheet.layoutSubtreeIfNeeded()

        XCTAssertEqual(sheet.displayedHeaderTitle, "Sign in with Apple")
        XCTAssertEqual(sheet.displayedPromptText, "Sign in to Janitor using your Apple Account.")
        XCTAssertEqual(sheet.displayedSecondaryActionTitle, "Use a different Apple Account")
        XCTAssertFalse(sheet.isShowingInteractiveWebAuth)

        let childWeb = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 460))
        sheet.revealInteractiveWebAuthView(childWeb)
        XCTAssertTrue(sheet.isShowingInteractiveWebAuth)
        XCTAssertNotNil(childWeb.superview)
    }

    func testMultiAccountPasskeySheetSelection() {
        let accounts = [
            SafariBiometricAccountOption(id: "id-1", title: "elfa@acme.test", subtitle: "Passkey · acme.test", initials: "EA"),
            SafariBiometricAccountOption(id: "id-2", title: "dev@acme.test", subtitle: "Passkey · acme.test", initials: "DA")
        ]
        let cfg = SafariBiometricSheetKind.PasskeySignInConfig(
            rpDisplayName: "Acme",
            rpId: "acme.test",
            siteIcon: nil,
            accounts: accounts,
            selectedAccountIndex: 0
        )
        let sheet = SafariBiometricSheetView(kind: .passkeySignIn(cfg))
        sheet.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        sheet.layoutSubtreeIfNeeded()

        XCTAssertEqual(sheet.displayedHeaderTitle, "Sign in")
        XCTAssertEqual(sheet.displayedPromptText, "Choose a passkey to sign in to Acme.")
        XCTAssertEqual(sheet.currentSelectedAccountIndex, 0)
    }

    func testPrivateBrowsingBiometricOverlayUnlockFlow() {
        let overlay = PrivateWindowLockOverlayView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let stub = StubEvaluator()
        stub.outcomes = [.failed(message: "Try again"), .matched]
        overlay.authenticatorFactory = { stub }

        var didUnlock = false
        overlay.beginBiometricUnlock(reason: "Unlock Private Browsing") {
            didUnlock = true
        }
        XCTAssertFalse(didUnlock)
        XCTAssertEqual(overlay.scannerView.state, .failed("Try again"))

        overlay.beginBiometricUnlock(reason: "Unlock Private Browsing") {
            didUnlock = true
        }
        XCTAssertTrue(didUnlock)
        XCTAssertEqual(overlay.scannerView.state, .matched)

        overlay.resetScannerState()
        XCTAssertEqual(overlay.scannerView.state, .idle)
    }
}
