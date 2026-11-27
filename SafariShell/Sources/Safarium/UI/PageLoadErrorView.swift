import AppKit

/// Represents a main-frame page load error to render with native macOS Safari styling.
struct BrowserPageLoadError: Equatable {
    let failedURL: URL
    let errorCode: Int
    let errorText: String

    var headingText: String {
        "Safarium Can’t Open the Page"
    }

    var detailText: String {
        let urlDisplay = failedURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host = failedURL.host ?? urlDisplay

        switch errorCode {
        case -105, -137: // ERR_NAME_NOT_RESOLVED / ERR_NAME_RESOLUTION_FAILED
            return "Safarium can’t open the page “\(urlDisplay)” because Safarium can’t find the server “\(host)”."
        case -106: // ERR_INTERNET_DISCONNECTED
            return "Safarium can’t open the page “\(urlDisplay)” because your Mac is not connected to the Internet."
        case -102: // ERR_CONNECTION_REFUSED
            return "Safarium can’t open the page “\(urlDisplay)” because Safarium can’t connect to the server “\(host)”."
        case -118, -7: // ERR_CONNECTION_TIMED_OUT / ERR_TIMED_OUT
            return "Safarium can’t open the page “\(urlDisplay)” because the server where this page is located isn’t responding."
        case -100, -101, -103, -104, -324: // CLOSED, RESET, ABORTED, FAILED, EMPTY_RESPONSE
            return "Safarium can’t open the page “\(urlDisplay)” because the server unexpectedly dropped the connection. This sometimes occurs when the server is busy. Wait for a few minutes, and then try again."
        case -310: // ERR_TOO_MANY_REDIRECTS
            return "Safarium can’t open the page “\(urlDisplay)” because too many redirects occurred trying to open “\(urlDisplay)”."
        case -217 ... -200, -107, -113, -117: // SSL / Certificate / TLS errors
            return "Safarium can’t open the page “\(urlDisplay)” because Safarium can’t establish a secure connection to the server “\(host)”."
        case -300, -301, -302: // INVALID_URL / DISALLOWED_SCHEME / UNKNOWN_URL_SCHEME
            return "Safarium can’t open “\(urlDisplay)” because macOS doesn’t recognize Internet addresses starting with “\(failedURL.scheme ?? "")”."
        default:
            let cleaned = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                return "Safarium can’t open the page “\(urlDisplay)” because the server unexpectedly dropped the connection. This sometimes occurs when the server is busy. Wait for a few minutes, and then try again."
            }
            return "Safarium can’t open the page “\(urlDisplay)” because an error occurred (\(cleaned))."
        }
    }
}

/// Authentic macOS Safari page load error screen matching `media_1795587695054_8082750f.png`:
/// - Crisp full-bleed `#F6F6F6` neutral backdrop
/// - Centered muted-slate San Francisco heading (`26pt` bold `#7E7E7E`)
/// - Centered clean explanatory copy (`13.5pt` regular `#7E7E7E`, max width `500pt`)
final class PageLoadErrorView: NSView {
    static let backdropColor = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.965, alpha: 1.0)

    private let stackView = NSStackView()
    private let headingLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Self.backdropColor.cgColor

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let slateInk = NSColor(srgbRed: 0.495, green: 0.495, blue: 0.498, alpha: 1.0)

        headingLabel.font = NSFont.systemFont(ofSize: 26.0, weight: .bold)
        headingLabel.textColor = slateInk
        headingLabel.alignment = .center
        headingLabel.lineBreakMode = .byWordWrapping
        headingLabel.maximumNumberOfLines = 2

        detailLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        detailLabel.textColor = slateInk
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 6
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stackView.addArrangedSubview(headingLabel)
        stackView.addArrangedSubview(detailLabel)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 12),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(error: BrowserPageLoadError) {
        headingLabel.stringValue = error.headingText
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 3.0
        detailLabel.attributedStringValue = NSAttributedString(
            string: error.detailText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: NSColor(srgbRed: 0.495, green: 0.495, blue: 0.498, alpha: 1.0),
                .paragraphStyle: para
            ]
        )
    }
}
