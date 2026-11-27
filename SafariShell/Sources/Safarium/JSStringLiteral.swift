import Foundation

/// Safe construction of JavaScript source fragments from untrusted Swift strings.
enum JSStringLiteral {
    /// Returns `s` as a double-quoted JavaScript string literal, escaping quotes, backslashes,
    /// control characters and the U+2028/U+2029 line separators so the value can never terminate the literal.
    static func make(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf16.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            case "<": out += "\\u003C"   // keeps "</script>" inert if ever inlined into HTML
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
