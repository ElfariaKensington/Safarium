import XCTest
import AppKit
@testable import Safarium

/// `URLInputNormalizer` reads `BrowserSettings.shared`, so every key this suite touches is removed in tearDown.
final class URLInputNormalizerTests: HermeticTestCase {
    private let touchedKeys = [
        BrowserSettings.Key.searchEngine,
        BrowserSettings.Key.samePrivateSearch,
        BrowserSettings.Key.privateSearchEngine,
        BrowserSettings.Key.quickWebsiteSearch,
        BrowserSettings.Key.showFullAddress,
        BrowserSettings.Key.homepage,
        "Safarium.QuickSearchSites.v1"
    ]

    override func setUp() {
        super.setUp()
        resetSettings()
    }

    override func tearDown() {
        resetSettings()
        super.tearDown()
    }

    private func resetSettings() {
        for key in touchedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func norm(_ input: String, isPrivate: Bool = false) -> String {
        URLInputNormalizer.normalize(input, isPrivate: isPrivate).absoluteString
    }

    private func googleSearch(_ query: String) -> String {
        BrowserSettings.SearchEngine.google.searchURL(for: query).absoluteString
    }

    // MARK: - Empty / whitespace

    func testEmptyInputGoesToStartPage() {
        XCTAssertEqual(norm(""), "safarium://start")
    }

    func testWhitespaceOnlyInputGoesToStartPage() {
        XCTAssertEqual(norm("   \n\t  "), "safarium://start")
    }

    func testSurroundingWhitespaceIsTrimmedBeforeClassification() {
        XCTAssertEqual(norm("   example.com  \n"), "https://example.com")
        XCTAssertEqual(norm("\t https://example.com/x \t"), "https://example.com/x")
    }

    // MARK: - Explicit schemes

    func testHTTPSURLIsKeptVerbatim() {
        XCTAssertEqual(norm("https://example.com/path?q=1#frag"), "https://example.com/path?q=1#frag")
    }

    func testHTTPURLIsKeptVerbatim() {
        XCTAssertEqual(norm("http://example.com"), "http://example.com")
    }

    func testInternalSchemesAreKeptVerbatim() {
        XCTAssertEqual(norm("safarium://start"), "safarium://start")
        XCTAssertEqual(norm("safarium://history"), "safarium://history")
        XCTAssertEqual(norm("about:blank"), "about:blank")
        XCTAssertEqual(norm("chrome://settings"), "chrome://settings")
        XCTAssertEqual(norm("chrome-extension://abcdef/popup.html"), "chrome-extension://abcdef/popup.html")
        XCTAssertEqual(norm("file:///tmp/a.html"), "file:///tmp/a.html")
        XCTAssertEqual(norm("view-source:https://example.com"), "view-source:https://example.com")
    }

    func testExplicitSchemeIsNotPrefixedWithHTTPS() {
        XCTAssertEqual(norm("http://localhost:8080/x"), "http://localhost:8080/x")
        XCTAssertFalse(norm("http://example.com").hasPrefix("https://http"))
    }

    func testExplicitSchemeKeepsQueryAndFragment() {
        XCTAssertEqual(norm("https://example.com/search?q=a%20b&lang=en#top"), "https://example.com/search?q=a%20b&lang=en#top")
    }

    func testMalformedExplicitURLWithSpaceFallsBackToSearch() {
        XCTAssertEqual(norm("https://exa mple.com"), googleSearch("https://exa mple.com"))
    }

    func testMalformedExplicitURLWithPercentIsSearched() {
        // Spaces make the explicit URL unparseable; the whole input becomes a search query.
        XCTAssertEqual(norm("http://bad url"), googleSearch("http://bad url"))
    }

    func testSchemeMatchIsPrefixBasedNotHostBased() {
        XCTAssertEqual(norm("about:"), "about:")
    }

    func testSchemeLikeTextWithoutRecognizedPrefixIsSearched() {
        // "javascript:" must never be treated as a URL.
        let url = URLInputNormalizer.normalize("javascript:alert(1)")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.google.com")
    }

    func testUppercaseHTTPSchemeIsRecognised() {
        XCTAssertEqual(norm("HTTP://example.com"), "HTTP://example.com")
    
    }

    func testMixedCaseHTTPSSchemeIsRecognised() {
        XCTAssertEqual(norm("Https://example.com/a"), "Https://example.com/a")
    
    }

    func testUppercaseInternalSchemeIsRecognised() {
        XCTAssertEqual(norm("SAFARIUM://start"), "SAFARIUM://start")
    
    }

    func testUppercaseAboutSchemeIsRecognised() {
        XCTAssertEqual(norm("ABOUT:blank"), "ABOUT:blank")
    
    }

    func testUnlistedSchemeWithDotIsNotBlindlyPrefixedWithHTTPS() {
        XCTAssertEqual(norm("ftp://example.com/file"), "ftp://example.com/file")
    
    }

    // MARK: - Bare domains

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(norm("example.com"), "https://example.com")
    }

    func testBareDomainWithPathAndQueryGetsHTTPS() {
        XCTAssertEqual(norm("example.com/path/to?x=1"), "https://example.com/path/to?x=1")
    }

    func testDomainWithPortGetsHTTPS() {
        XCTAssertEqual(norm("example.com:8443"), "https://example.com:8443")
    }

    func testIPv4AddressGetsHTTP() {
        XCTAssertEqual(norm("192.168.1.1"), "http://192.168.1.1")
        XCTAssertEqual(norm("127.0.0.1:8080/api"), "http://127.0.0.1:8080/api")
    }

    func testLocalhostWithPortAndPathGetsHTTP() {
        XCTAssertEqual(norm("localhost:3000/app.js"), "http://localhost:3000/app.js")
    }

    func testBareLocalhostGetsHTTPNotSearched() {
        // Regression (found by live test drive): typing localhost[:port] used to run a web search.
        XCTAssertEqual(norm("localhost"), "http://localhost")
        XCTAssertEqual(norm("localhost:8080"), "http://localhost:8080")
    }

    func testBracketedIPv6LiteralGetsHTTPButBareColonFormIsSearched() {
        XCTAssertEqual(norm("[::1]"), "http://[::1]")
        XCTAssertEqual(norm("::1"), googleSearch("::1"))
    }

    func testExplicitIPv6URLIsKept() {
        XCTAssertEqual(norm("http://[::1]:8080/"), "http://[::1]:8080/")
        XCTAssertEqual(norm("https://[::1]:443/a"), "https://[::1]:443/a")
    }

    func testTrailingDotDomainIsAccepted() {
        XCTAssertEqual(norm("example.com."), "https://example.com.")
    }

    func testUnicodeDomainIsAccepted() {
        XCTAssertEqual(norm("bücher.de"), "https://xn--bcher-kva.de", "IDN host is punycoded by URL(string:)")
    }

    func testDomainLikeTokenWithTabIsSearched() {
        // A tab is not the " " character the rule checks for, but it is not a valid URL character.
        XCTAssertEqual(norm("exa\tmple.com"), googleSearch("exa\tmple.com"))
    }

    func testVeryLongDomainLikeInputIsStillAUrl() {
        let host = String(repeating: "a", count: 240) + ".com"
        XCTAssertEqual(norm(host), "https://" + host)
    }

    // MARK: - Search fallback

    func testPlainWordIsSearched() {
        XCTAssertEqual(norm("swift"), googleSearch("swift"))
    }

    func testMultiWordInputIsSearchedWithEncodedSpaces() {
        XCTAssertEqual(norm("how to bake bread"), "https://www.google.com/search?q=how%20to%20bake%20bread")
    }

    func testDomainLikeTextWithSpaceIsSearched() {
        XCTAssertEqual(norm("my site.com"), googleSearch("my site.com"))
    }

    func testAmpersandAndHashAreEncodedInSearch() {
        let url = URLInputNormalizer.normalize("a&b c#d")
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=a%26b%20c%23d")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b c#d")
    }

    func testPlusIsEncodedInSearch() {
        XCTAssertEqual(norm("c++ language"), "https://www.google.com/search?q=c%2B%2B%20language")
    
    }

    func testQuestionMarkSearchRoundTrips() {
        let url = URLInputNormalizer.normalize("why is the sky blue?")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "why is the sky blue?")
    }

    func testUnicodeSearchIsPercentEncodedUTF8() {
        XCTAssertEqual(norm("東京 天気"), "https://www.google.com/search?q=%E6%9D%B1%E4%BA%AC%20%E5%A4%A9%E6%B0%97")
    }

    func testEmojiSearchRoundTrips() {
        let url = URLInputNormalizer.normalize("🙂 smile")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "🙂 smile")
    }

    func testSingleCharacterIsSearched() {
        XCTAssertEqual(norm("x"), googleSearch("x"))
    }

    func testVeryLongSearchInputRoundTrips() {
        let query = String(repeating: "word ", count: 1000).trimmingCharacters(in: .whitespaces)
        let url = URLInputNormalizer.normalize(query)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
    }

    func testSearchUsesConfiguredPrimaryEngine() {
        BrowserSettings.shared.set(6, forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(norm("cats"), "https://kagi.com/search?q=cats")
    }

    func testInvalidConfiguredEngineFallsBackToGoogle() {
        BrowserSettings.shared.set(500, forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(norm("cats"), googleSearch("cats"))
    }

    // MARK: - Private search selection

    func testPrivateInputUsesPrivateEngineWhenSeparate() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        BrowserSettings.shared.set(1, forKey: BrowserSettings.Key.privateSearchEngine)
        XCTAssertEqual(norm("cats", isPrivate: true), "https://duckduckgo.com/?q=cats")
        XCTAssertEqual(norm("cats", isPrivate: false), googleSearch("cats"))
    }

    func testPrivateInputUsesPrimaryEngineWhenShared() {
        BrowserSettings.shared.set(true, forKey: BrowserSettings.Key.samePrivateSearch)
        BrowserSettings.shared.set(2, forKey: BrowserSettings.Key.privateSearchEngine)
        XCTAssertEqual(norm("cats", isPrivate: true), googleSearch("cats"))
    }

    func testPrivateEngineIsNotUsedForURLs() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        XCTAssertEqual(norm("example.com", isPrivate: true), "https://example.com")
        XCTAssertEqual(norm("https://example.com", isPrivate: true), "https://example.com")
    }

    func testPrivateEngineIsUsedForPlainSearchInPrivateMode() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        BrowserSettings.shared.set(3, forKey: BrowserSettings.Key.privateSearchEngine)
        XCTAssertEqual(norm("cats", isPrivate: true), "https://search.yahoo.com/search?p=cats")
    }

    // MARK: - Quick website search

    func testQuickSearchUsesKeywordSiteTemplate() {
        XCTAssertEqual(norm("youtube rust tutorial"), "https://www.youtube.com/results?search_query=rust%20tutorial")
    }

    func testQuickSearchKeywordIsCaseInsensitive() {
        XCTAssertEqual(norm("GitHub cef"), "https://github.com/search?q=cef")
    }

    func testQuickSearchDomainKeywordWorks() {
        XCTAssertEqual(norm("github.com swift"), "https://github.com/search?q=swift")
    }

    func testQuickSearchWinsOverBareDomainOnlyWhenSpacePresent() {
        // "github.com" with no query is a bare domain, so it goes to HTTPS, not quick search.
        XCTAssertEqual(norm("github.com"), "https://github.com")
    }

    func testQuickSearchKeywordWithoutQueryIsSearched() {
        XCTAssertEqual(norm("youtube"), googleSearch("youtube"))
    }

    func testQuickSearchDisabledFallsBackToSearchEngine() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.quickWebsiteSearch)
        XCTAssertEqual(norm("github cef"), googleSearch("github cef"))
    }

    func testQuickSearchAppliesInPrivateMode() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        XCTAssertEqual(norm("github cef", isPrivate: true), "https://github.com/search?q=cef")
    }

    func testQuickSearchSpecialCharactersAreEncoded() {
        XCTAssertEqual(norm("github a&b"), "https://github.com/search?q=a%26b")
        XCTAssertEqual(norm("amazon usb-c=3 #1"), "https://www.amazon.com/s?k=usb-c%3D3%20%231")
    }

    func testQuickSearchWithCustomSitesFromSettings() {
        BrowserSettings.shared.saveQuickSearchSites([
            .init(keyword: "ddg", domain: "duckduckgo.com", templateURL: "https://duckduckgo.com/?q=%@")
        ])
        XCTAssertEqual(norm("ddg apple pie"), "https://duckduckgo.com/?q=apple%20pie")
        XCTAssertEqual(norm("youtube rust"), googleSearch("youtube rust"), "default sites are replaced once custom sites are saved")
    }

    // MARK: - Homepage does not affect normalization

    func testHomepageSettingDoesNotChangeEmptyInput() {
        BrowserSettings.shared.set("example.com", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(norm(""), "safarium://start")
    }

    // MARK: - displayDomain

    func testDisplayDomainNilIsStartPage() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: nil), "Start Page")
    }

    func testDisplayDomainForInternalSafariumScheme() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "safarium://start")), "Search or enter website name")
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "safarium://history")), "Search or enter website name")
    }

    func testDisplayDomainStripsLeadingWWW() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://www.example.com/a/b")), "example.com")
    }

    func testDisplayDomainKeepsOtherSubdomainsAndDropsPort() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://docs.example.com:8443/x")), "docs.example.com")
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://wwwexample.com")), "wwwexample.com")
    }

    func testDisplayDomainOnlyStripsOneWWW() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://www.www.example.com")), "www.example.com")
    }

    func testDisplayDomainForIPAddress() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "http://192.168.0.1:80/")), "192.168.0.1")
    }

    func testDisplayDomainHostlessURLShowsAbsoluteString() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "about:blank")), "about:blank")
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "file:///tmp/x.txt")), "file:///tmp/x.txt")
    }

    func testDisplayDomainFullAddressPreference() {
        BrowserSettings.shared.set(true, forKey: BrowserSettings.Key.showFullAddress)
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://www.example.com/a?b=1")), "https://www.example.com/a?b=1")
    }

    func testDisplayDomainFullAddressDoesNotChangeStartPage() {
        BrowserSettings.shared.set(true, forKey: BrowserSettings.Key.showFullAddress)
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "safarium://start")), "Search or enter website name")
    }

    func testDisplayDomainUppercaseWWWIsStripped() {
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: URL(string: "https://WWW.Example.com")), "example.com")
    
    }

    func testLocalHostDetection() {
        for yes in ["localhost", "localhost:3000", "LOCALHOST/x", "foo.localhost", "printer.local", "10.0.0.5", "127.0.0.1:8765/vid.html", "[::1]:8080", "192.168.1.1?q=1"] {
            XCTAssertTrue(URLInputNormalizer.isLocalHostInput(yes), yes)
        }
        for no in ["example.com", "localhost.example.com", "1.2.3", "300.1.1.1", "10.0.0.5.6", "localhost:", "localhost:abc", "apple.com:8080", "notlocal", "a.local.b"] {
            XCTAssertFalse(URLInputNormalizer.isLocalHostInput(no), no)
        }
    }
}
