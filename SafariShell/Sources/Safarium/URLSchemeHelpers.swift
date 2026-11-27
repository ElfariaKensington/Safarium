import Foundation

extension URL {
    /// True for http/https URLs regardless of the scheme's letter case (`HTTP://example.com` is a web URL too).
    var isWebURL: Bool {
        guard let s = scheme?.lowercased() else { return false }
        return s == "http" || s == "https"
    }
}
