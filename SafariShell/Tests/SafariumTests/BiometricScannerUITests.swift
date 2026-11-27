import XCTest
import AppKit
@testable import Safarium

/// Hermetic unit and layout tests for Safari's native biometric scanner widget (`SafariBiometricScannerView`),
/// and the Private Browsing lock overlay.
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
