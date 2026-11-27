import XCTest
import AppKit
@testable import Safarium

/// Covers `BrowserPageLoadError` copy for every error-code range and the `PageLoadErrorView` configure path.
@MainActor
final class PageLoadErrorViewTests: HermeticTestCase {
    private func err(_ code: Int, url: String = "https://example.com/", text: String = "") -> BrowserPageLoadError {
        BrowserPageLoadError(failedURL: URL(string: url)!, errorCode: code, errorText: text)
    }

    /// Standard prefix for example.com pages: the URL is shown without its trailing slash.
    private func page(_ reason: String) -> String {
        "Safarium can’t open the page “https://example.com” because \(reason)"
    }

    private let dropped = "the server unexpectedly dropped the connection. This sometimes occurs when the server is busy. Wait for a few minutes, and then try again."

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.setUpIsolated() }
    }

    private func setUpIsolated() {
        _ = NSApplication.shared
    }

    // MARK: heading

    func testHeadingIsSameForEveryErrorCode() {
        for code in [-105, -106, -102, -7, -100, -310, -200, -300, 0, 42] {
            XCTAssertEqual(err(code).headingText, "Safarium Can’t Open the Page", "code \(code)")
        }
    }

    // MARK: name resolution

    func testNameNotResolvedCode105() {
        XCTAssertEqual(err(-105).detailText, page("Safarium can’t find the server “example.com”."))
    }

    func testNameResolutionFailedCode137UsesSameCopy() {
        XCTAssertEqual(err(-137).detailText, err(-105).detailText)
    }

    // MARK: connectivity

    func testInternetDisconnectedCode106() {
        XCTAssertEqual(err(-106).detailText, page("your Mac is not connected to the Internet."))
    }

    func testConnectionRefusedCode102() {
        XCTAssertEqual(err(-102).detailText, page("Safarium can’t connect to the server “example.com”."))
    }

    func testConnectionTimedOutCode118() {
        XCTAssertEqual(err(-118).detailText, page("the server where this page is located isn’t responding."))
    }

    func testTimedOutCode7UsesSameCopy() {
        XCTAssertEqual(err(-7).detailText, err(-118).detailText)
    }

    func testDroppedConnectionCodesShareCopy() {
        for code in [-100, -101, -103, -104, -324] {
            XCTAssertEqual(err(code).detailText, page(dropped), "code \(code)")
        }
    }

    func testTooManyRedirectsCode310QuotesURLTwice() {
        XCTAssertEqual(
            err(-310).detailText,
            "Safarium can’t open the page “https://example.com” because too many redirects occurred trying to open “https://example.com”."
        )
    }

    // MARK: TLS / certificate range

    func testTLSRangeLowerBoundCode217() {
        XCTAssertEqual(err(-217).detailText, page("Safarium can’t establish a secure connection to the server “example.com”."))
    }

    func testTLSRangeUpperBoundCode200() {
        XCTAssertEqual(err(-200).detailText, err(-217).detailText)
    }

    func testTLSRangeMiddleCode205() {
        XCTAssertEqual(err(-205).detailText, err(-217).detailText)
    }

    func testTLSExtraCodesOutsideRangeCode107_113_117() {
        for code in [-107, -113, -117] {
            XCTAssertEqual(err(code).detailText, err(-217).detailText, "code \(code)")
        }
    }

    func testCodeJustBelowTLSRangeFallsBackToGenericCopy() {
        XCTAssertEqual(err(-218, text: "X").detailText, page("an error occurred (X)."))
    }

    func testCodeJustAboveTLSRangeFallsBackToGenericCopy() {
        XCTAssertEqual(err(-199, text: "X").detailText, page("an error occurred (X)."))
    }

    // MARK: URL scheme errors

    func testInvalidURLCodesUseSchemeCopy() {
        for code in [-300, -301, -302] {
            XCTAssertEqual(
                err(code, url: "foo:bar").detailText,
                "Safarium can’t open “foo:bar” because macOS doesn’t recognize Internet addresses starting with “foo”.",
                "code \(code)"
            )
        }
    }

    func testSchemeCopyUsesHTTPSSchemeForHTTPSURL() {
        XCTAssertEqual(
            err(-302).detailText,
            "Safarium can’t open “https://example.com” because macOS doesn’t recognize Internet addresses starting with “https”."
        )
    }

    // MARK: default branch

    func testUnknownCodeWithEmptyTextUsesDroppedCopy() {
        XCTAssertEqual(err(-999).detailText, page(dropped))
    }

    func testUnknownCodeWithWhitespaceOnlyTextUsesDroppedCopy() {
        XCTAssertEqual(err(-999, text: " \n\t  ").detailText, page(dropped))
    }

    func testUnknownCodeTrimsErrorText() {
        XCTAssertEqual(err(-999, text: "  Something broke \n").detailText, page("an error occurred (Something broke)."))
    }

    func testUnknownCodeKeepsInnerWhitespace() {
        XCTAssertEqual(err(-999, text: "two  words").detailText, page("an error occurred (two  words)."))
    }

    func testUnknownCodeWithUnicodeErrorText() {
        XCTAssertEqual(err(-999, text: "Fehler ✗ 错误").detailText, page("an error occurred (Fehler ✗ 错误)."))
    }

    func testZeroCodeUsesDefaultBranch() {
        XCTAssertEqual(err(0, text: "ok").detailText, page("an error occurred (ok)."))
    }

    // MARK: URL display

    func testTrailingSlashesAreTrimmedFromDisplayedURL() {
        let e = err(-106, url: "https://example.com/a/b/")
        XCTAssertEqual(
            e.detailText,
            "Safarium can’t open the page “https://example.com/a/b” because your Mac is not connected to the Internet."
        )
    }

    func testQueryStringIsKeptInDisplayedURL() {
        let e = err(-106, url: "https://example.com/search?q=swift")
        XCTAssertTrue(e.detailText.contains("“https://example.com/search?q=swift”"))
    }

    func testPercentEncodedPathIsKeptVerbatim() {
        let e = err(-106, url: "https://example.com/caf%C3%A9")
        XCTAssertTrue(e.detailText.contains("“https://example.com/caf%C3%A9”"))
    }

    func testServerNameUsesHostWithoutPath() {
        let e = err(-102, url: "https://shop.example.co.uk/cart/item")
        XCTAssertTrue(e.detailText.hasSuffix("connect to the server “shop.example.co.uk”."))
    }

    func testHostlessURLUsesDisplayStringAsServerName() {
        // "foo:bar" has no host, so the server name falls back to the display string.
        let e = err(-105, url: "foo:bar")
        XCTAssertEqual(e.detailText, "Safarium can’t open the page “foo:bar” because Safarium can’t find the server “foo:bar”.")
    }

    func testPortIsPartOfServerNameHostOnly() {
        // Host excludes the port, matching how the server name is shown.
        let e = err(-102, url: "http://localhost:8080/app")
        XCTAssertTrue(e.detailText.hasSuffix("connect to the server “localhost”."))
    }

    func testHTTPSchemeSurvivesDisplay() {
        let e = err(-106, url: "http://example.com")
        XCTAssertTrue(e.detailText.contains("“http://example.com”"))
    }

    // MARK: Equatable

    func testEqualityRequiresSameURLCodeAndText() {
        XCTAssertEqual(err(-106), err(-106))
        XCTAssertNotEqual(err(-106), err(-102))
        XCTAssertNotEqual(err(-106), err(-106, url: "https://example.org/"))
        XCTAssertNotEqual(err(-999, text: "a"), err(-999, text: "b"))
    }

    // MARK: view

    private func labels(in view: PageLoadErrorView) -> [NSTextField] {
        guard let stack = view.subviews.compactMap({ $0 as? NSStackView }).first else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? NSTextField }
    }

    func testViewStartsWithEmptyLabels() {
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let texts = labels(in: view).map(\.stringValue)
        XCTAssertEqual(texts, ["", ""])
    }

    func testConfigureFillsHeadingAndDetail() {
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let e = err(-102)
        view.configure(error: e)
        let l = labels(in: view)
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].stringValue, "Safarium Can’t Open the Page")
        XCTAssertEqual(l[1].stringValue, e.detailText)
    }

    func testConfigureReplacesPreviousText() {
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.configure(error: err(-102))
        view.configure(error: err(-106))
        XCTAssertEqual(labels(in: view)[1].stringValue, page("your Mac is not connected to the Internet."))
    }

    func testConfigureCentersDetailTextWithStyledFont() {
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.configure(error: err(-106))
        let detail = labels(in: view)[1]
        let attr = detail.attributedStringValue
        XCTAssertEqual(attr.length, detail.stringValue.count)
        let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 13.5)
        let para = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.alignment, .center)
        XCTAssertEqual(para?.lineSpacing, 3.0)
    }

    func testBackdropColorIsNeutralLightGray() {
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let cg = view.layer?.backgroundColor
        XCTAssertNotNil(cg)
        let c = NSColor(cgColor: cg!)?.usingColorSpace(.sRGB)
        XCTAssertEqual(c?.redComponent ?? -1, 0.965, accuracy: 0.002)
        XCTAssertEqual(c?.greenComponent ?? -1, 0.965, accuracy: 0.002)
        XCTAssertEqual(c?.blueComponent ?? -1, 0.965, accuracy: 0.002)
        XCTAssertEqual(PageLoadErrorView.backdropColor.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testViewIsNotAutoresizingBecauseItUsesConstraints() {
        let view = PageLoadErrorView(frame: .zero)
        XCTAssertFalse(view.translatesAutoresizingMaskIntoConstraints)
    }

    func testLongURLConfiguresWithoutLosingTail() {
        let longPath = String(repeating: "segment/", count: 60) + "end"
        let e = err(-106, url: "https://example.com/" + longPath)
        let view = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.configure(error: e)
        XCTAssertTrue(labels(in: view)[1].stringValue.hasSuffix("because your Mac is not connected to the Internet."))
        XCTAssertTrue(labels(in: view)[1].stringValue.contains("/end”"))
    }
}
