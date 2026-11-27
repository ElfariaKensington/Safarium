import JavaScriptCore
import XCTest
@testable import Safarium

/// JSStringLiteral must always produce a single-line, double-quoted literal that JavaScript reads back
/// as exactly the input string, and must never let a payload terminate the literal or close a <script>.
final class JSStringLiteralTests: HermeticTestCase {
    /// Deterministic linear congruential generator so the property-style cases are reproducible.
    private struct LCG {
        var state: UInt64
        mutating func next(below bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private static let hostileScalars: [Unicode.Scalar] = [
        "a", "Z", "0", " ", "\"", "'", "\\", "\n", "\r", "\t", "`", "$", "{", "}", "<", ">", "/", "&", ";",
        "\u{0}", "\u{1}", "\u{8}", "\u{B}", "\u{C}", "\u{1B}", "\u{1F}", "\u{7F}",
        "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{FFFD}", "\u{E000}", "\u{200D}",
        "\u{00E9}", "\u{4E16}", "\u{1F600}", "\u{10FFFF}"
    ]

    private static let hostileSamples: [String] = [
        "", "plain", "\"", "\\", "\\\"", "\"; alert(1); \"", "</script><script>alert(1)</script>",
        "line1\nline2", "carriage\rreturn", "tab\there", "\u{2028}\u{2029}", "nul\u{0}byte",
        "bell\u{7}", "del\u{7F}", "emoji \u{1F600} family \u{1F468}\u{200D}\u{1F469}", "\\u0041 not an escape",
        "`${injected}`", "it's", "end with backslash \\", "$('</div>')", "<!-- comment -->",
        "\u{FEFF}bom", "combining e\u{301}", "\u{10FFFF}", String(repeating: "\"\\<", count: 300)
    ]

    private func makeContext() -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, _ in }
        return context
    }

    /// Evaluates `literal` as a JavaScript expression and returns its string value, or nil on any JS exception.
    private func evaluate(_ literal: String, in context: JSContext) -> String? {
        context.exception = nil
        let value = context.evaluateScript("(" + literal + ")")
        guard context.exception == nil, let value, value.isString else { return nil }
        return value.toString()
    }

    private func assertRoundTrips(_ input: String, in context: JSContext, file: StaticString = #filePath, line: UInt = #line) {
        let literal = JSStringLiteral.make(input)
        guard let decoded = evaluate(literal, in: context) else {
            XCTFail("literal did not evaluate to a string: \(literal.debugDescription)", file: file, line: line)
            return
        }
        XCTAssertTrue(decoded.unicodeScalars.elementsEqual(input.unicodeScalars),
                      "round trip mismatch for input \(input.debugDescription); literal \(literal.debugDescription)",
                      file: file, line: line)
    }

    private func assertSafeLiteralShape(_ literal: String, file: StaticString = #filePath, line: UInt = #line) {
        let scalars = Array(literal.unicodeScalars)
        XCTAssertTrue(scalars.count >= 2 && scalars.first == "\"" && scalars.last == "\"", "not double-quoted: \(literal.debugDescription)", file: file, line: line)
        XCTAssertFalse(literal.contains("<"), "raw < escapes the literal to HTML: \(literal.debugDescription)", file: file, line: line)
        XCTAssertFalse(literal.contains("\u{2028}"), file: file, line: line)
        XCTAssertFalse(literal.contains("\u{2029}"), file: file, line: line)
        XCTAssertFalse(literal.contains("\n"), file: file, line: line)
        XCTAssertFalse(literal.contains("\r"), file: file, line: line)
        XCTAssertFalse(literal.lowercased().contains("</script"), file: file, line: line)
        for scalar in literal.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            XCTFail("raw control scalar U+\(String(scalar.value, radix: 16)) leaked into literal", file: file, line: line)
        }
    }

    // MARK: - Exact output

    func testEmptyStringProducesEmptyQuotedLiteral() {
        XCTAssertEqual(JSStringLiteral.make(""), "\"\"")
    }

    func testPlainASCIIIsQuotedVerbatim() {
        XCTAssertEqual(JSStringLiteral.make("hello world 123 !?#%^*()-_=+[]:,."), "\"hello world 123 !?#%^*()-_=+[]:,.\"")
    }

    func testDoubleQuotesAreEscaped() {
        XCTAssertEqual(JSStringLiteral.make("say \"hi\""), "\"say \\\"hi\\\"\"")
    }

    func testBackslashesAreEscapedBeforeQuotes() {
        XCTAssertEqual(JSStringLiteral.make("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(JSStringLiteral.make("\\\""), "\"" + "\\\\" + "\\\"" + "\"")
    }

    func testNamedControlCharactersUseShortEscapes() {
        XCTAssertEqual(JSStringLiteral.make("\n"), "\"\\n\"")
        XCTAssertEqual(JSStringLiteral.make("\r"), "\"\\r\"")
        XCTAssertEqual(JSStringLiteral.make("\t"), "\"\\t\"")
        XCTAssertEqual(JSStringLiteral.make("\u{08}"), "\"\\b\"")
        XCTAssertEqual(JSStringLiteral.make("\u{0C}"), "\"\\f\"")
    }

    func testOtherControlCharactersUseUnicodeEscapes() {
        XCTAssertEqual(JSStringLiteral.make("\u{00}"), "\"\\u0000\"")
        XCTAssertEqual(JSStringLiteral.make("\u{01}"), "\"\\u0001\"")
        XCTAssertEqual(JSStringLiteral.make("\u{0B}"), "\"\\u000B\"")
        XCTAssertEqual(JSStringLiteral.make("\u{1F}"), "\"\\u001F\"")
        XCTAssertEqual(JSStringLiteral.make("\u{7F}"), "\"\\u007F\"")
    }

    func testLineAndParagraphSeparatorsAreEscaped() {
        XCTAssertEqual(JSStringLiteral.make("\u{2028}"), "\"\\u2028\"")
        XCTAssertEqual(JSStringLiteral.make("\u{2029}"), "\"\\u2029\"")
    }

    func testLessThanIsAlwaysEscapedSoScriptCloserIsInert() {
        XCTAssertEqual(JSStringLiteral.make("</script>"), "\"\\u003C/script>\"")
        XCTAssertFalse(JSStringLiteral.make("<<<").contains("<"))
    }

    func testGreaterThanAndSlashAreLeftAlone() {
        XCTAssertEqual(JSStringLiteral.make("a>b/c"), "\"a>b/c\"")
    }

    func testNonASCIIIsPassedThroughUnchanged() {
        XCTAssertEqual(JSStringLiteral.make("h\u{00E9}llo \u{4E16}\u{754C} \u{1F600}"), "\"h\u{00E9}llo \u{4E16}\u{754C} \u{1F600}\"")
    }

    func testSingleQuotesBackticksAndTemplateSyntaxAreNotSpecial() {
        XCTAssertEqual(JSStringLiteral.make("it's `x` ${y}"), "\"it's `x` ${y}\"")
    }

    func testIsDeterministic() {
        let input = "repeat \u{1F600} \"x\" \\ </script>"
        XCTAssertEqual(JSStringLiteral.make(input), JSStringLiteral.make(input))
    }

    // MARK: - Shape guarantees

    func testLiteralShapeHoldsForEverySampleAndScalar() {
        for sample in Self.hostileSamples {
            assertSafeLiteralShape(JSStringLiteral.make(sample))
        }
        for scalar in Self.hostileScalars {
            assertSafeLiteralShape(JSStringLiteral.make(String(Character(scalar))))
        }
    }

    func testLiteralEscapesEveryUnsafeScalarIndividually() {
        for scalar in Self.hostileScalars {
            let scalars = Array(JSStringLiteral.make(String(Character(scalar))).unicodeScalars)
            var index = 1
            while index < scalars.count - 1 {
                if scalars[index] == "\\" {
                    index += 2
                    continue
                }
                XCTAssertNotEqual(scalars[index], "\"", "unescaped quote for U+\(String(scalar.value, radix: 16))")
                index += 1
            }
        }
    }

    // MARK: - JavaScriptCore round trips

    func testHostileSamplesRoundTripThroughJavaScriptCore() {
        let context = makeContext()
        for sample in Self.hostileSamples {
            assertRoundTrips(sample, in: context)
        }
    }

    func testEveryHostileScalarRoundTripsThroughJavaScriptCore() {
        let context = makeContext()
        for scalar in Self.hostileScalars {
            assertRoundTrips(String(Character(scalar)), in: context)
        }
    }

    func testRandomHostileStringsRoundTripThroughJavaScriptCore() {
        var rng = LCG(state: 0x5AFA_12)
        let context = makeContext()
        for _ in 0..<400 {
            let length = rng.next(below: 48)
            var text = ""
            for _ in 0..<length {
                text.unicodeScalars.append(Self.hostileScalars[rng.next(below: Self.hostileScalars.count)])
            }
            assertRoundTrips(text, in: context)
            assertSafeLiteralShape(JSStringLiteral.make(text))
        }
    }

    func testPayloadCannotEscapeTheLiteralIntoCode() {
        let context = makeContext()
        let payload = "\"; globalThis.pwned = true; \""
        context.exception = nil
        context.evaluateScript("var __value = \(JSStringLiteral.make(payload));")
        XCTAssertNil(context.exception, "the payload must not produce a syntax error or run code")
        XCTAssertEqual(context.objectForKeyedSubscript("__value")?.toString(), payload)
        XCTAssertEqual(context.objectForKeyedSubscript("pwned")?.isUndefined, true)
    }

    func testLineSeparatorPayloadCannotBreakTheStatement() {
        let context = makeContext()
        let payload = "x\u{2028}y\u{2029}z"
        context.exception = nil
        context.evaluateScript("var __sep = \(JSStringLiteral.make(payload));")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("__sep")?.toString(), payload)
    }

    func testLargeInputRoundTrips() {
        let context = makeContext()
        let big = String(repeating: "a\"\\<\u{1F600}\n", count: 2_000)
        assertRoundTrips(big, in: context)
        assertSafeLiteralShape(JSStringLiteral.make(big))
    }
}
