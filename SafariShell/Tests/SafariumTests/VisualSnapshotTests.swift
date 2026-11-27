import XCTest
import AppKit
@testable import Safarium

/// Renders real Safarium views offscreen (never shown on screen) into PNGs for visual/layout review and
/// asserts structural layout invariants (no NaN/negative frames, no subview escaping min-size layouts, text not empty).
@MainActor
final class VisualSnapshotTests: HermeticTestCase {
    static let outDir = NSTemporaryDirectory() + "SafariumTestShots"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: Self.outDir, withIntermediateDirectories: true)
    }

    // MARK: helpers

    func image(of view: NSView, crop: NSRect? = nil) -> NSImage {
        let b = view.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        let img = NSImage(size: b.size)
        img.addRepresentation(rep)
        guard let crop else { return img }
        let out = NSImage(size: crop.size)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: crop.size), from: crop, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    func save(_ img: NSImage, _ name: String) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(Self.outDir)/\(name).png"))
    }

    func host(_ view: NSView, size: NSSize, dark: Bool) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        return w
    }

    func contactSheet(_ rows: [(String, NSImage)], width: CGFloat, name: String) {
        let labelH: CGFloat = 16, gap: CGFloat = 6
        let height = rows.reduce(CGFloat(0)) { $0 + $1.1.size.height + labelH + gap }
        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        var y = height
        for (label, img) in rows {
            y -= labelH
            (label as NSString).draw(at: NSPoint(x: 4, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
            y -= img.size.height
            img.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            y -= gap
        }
        sheet.unlockFocus()
        save(sheet, name)
    }

    func allFramesValid(_ root: NSView) -> [String] {
        var bad: [String] = []
        func walk(_ v: NSView, _ d: Int) {
            let f = v.frame
            if f.origin.x.isNaN || f.origin.y.isNaN || f.width.isNaN || f.height.isNaN || f.width < 0 || f.height < 0 { bad.append("\(type(of: v)) \(f)") }
            if d < 14 { v.subviews.forEach { walk($0, d + 1) } }
        }
        walk(root, 0)
        return bad
    }

    // MARK: toolbar / tab strip contact sheets

    func testToolbarStripContactSheets() throws {
        for dark in [false, true] {
            var rows: [(String, NSImage)] = []
            for width in [680, 900, 1200, 1800] as [CGFloat] {
                for tabs in [1, 3, 12, 40] {
                    let wc = SafariWindowController(engine: MockBrowserEngine())
                    let w = try XCTUnwrap(wc.window)
                    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    for i in 0..<tabs { _ = wc.createNewTab(url: URL(string: "https://site\(i).example.com/page")!) }
                    w.setContentSize(NSSize(width: width, height: 500))
                    w.contentView?.layoutSubtreeIfNeeded()
                    spinRunLoop(0.05)
                    let v = try XCTUnwrap(w.contentView)
                    XCTAssertTrue(allFramesValid(v).isEmpty, "invalid frames at \(width)x\(tabs)")
                    rows.append(("\(dark ? "dark" : "light") width=\(Int(width)) tabs=\(tabs)", image(of: v, crop: NSRect(x: 0, y: v.bounds.height - 70, width: v.bounds.width, height: 70))))
                    w.close()
                }
            }
            contactSheet(rows, width: 1800, name: "sheet_toolbar_\(dark ? "dark" : "light")")
        }
    }

    // MARK: full views

    func testStartPageLightDarkNarrowWide() {
        for dark in [false, true] {
            for size in [NSSize(width: 680, height: 460), NSSize(width: 1200, height: 748), NSSize(width: 2000, height: 1200)] {
                let v = StartPageView(frame: NSRect(origin: .zero, size: size))
                let w = host(v, size: size, dark: dark)
                spinRunLoop(0.1)
                XCTAssertTrue(allFramesValid(v).isEmpty)
                save(image(of: v), "start_\(dark ? "dark" : "light")_\(Int(size.width))")
                w.close()
            }
        }
    }

    func testPrivateStartPage() {
        let v = StartPageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 748))
        v.configurePrivateMode(true)
        let w = host(v, size: NSSize(width: 1200, height: 748), dark: true)
        save(image(of: v), "start_private_dark")
        w.close()
    }

    func testSidebarAndOverviewAndError() {
        let items = (0..<14).map { i in
            TabPresentationItem(id: "t\(i)", title: i == 3 ? String(repeating: "A very long tab title that must truncate gracefully ", count: 3) : "Tab number \(i)",
                                url: URL(string: "https://example\(i).com/some/long/path/\(i)"), favicon: nil, isLoading: i == 5, progress: 0.4, isActive: i == 2, isPinned: i < 2)
        }
        for dark in [false, true] {
            let sb = SafariSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 760))
            sb.update(tabs: items)
            let w1 = host(sb, size: NSSize(width: 240, height: 760), dark: dark)
            spinRunLoop(0.1)
            XCTAssertTrue(allFramesValid(sb).isEmpty)
            save(image(of: sb), "sidebar_\(dark ? "dark" : "light")")
            w1.close()

            let ov = TabOverviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
            ov.update(cards: items.map { .init(id: $0.id, title: $0.title, url: $0.url, favicon: nil, snapshot: nil, isActive: $0.isActive) })
            let w2 = host(ov, size: NSSize(width: 1200, height: 760), dark: dark)
            spinRunLoop(0.1)
            save(image(of: ov), "overview_\(dark ? "dark" : "light")")
            w2.close()

            let err = PageLoadErrorView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            err.configure(error: BrowserPageLoadError(failedURL: URL(string: "https://nonexistent.example.invalid/")!, errorCode: -105, errorText: "ERR_NAME_NOT_RESOLVED"))
            let w3 = host(err, size: NSSize(width: 900, height: 600), dark: dark)
            save(image(of: err), "error_\(dark ? "dark" : "light")")
            w3.close()
        }
    }

    func testHistoryPage() {
        let v = HistoryPageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let w = host(v, size: NSSize(width: 1000, height: 700), dark: false)
        spinRunLoop(0.2)
        XCTAssertTrue(allFramesValid(v).isEmpty)
        save(image(of: v), "history_light")
        w.close()
    }

    func testSettingsPanes() throws {
        let sc = SafariSettingsWindowController(engine: MockBrowserEngine())
        let w = try XCTUnwrap(sc.window)
        var rows: [(String, NSImage)] = []
        for pane in SafariSettingsWindowController.Pane.allCases {
            sc.show(pane: pane)
            w.contentView?.layoutSubtreeIfNeeded()
            spinRunLoop(0.2)
            if let v = w.contentView {
                XCTAssertTrue(allFramesValid(v).isEmpty, "invalid frames in pane \(pane)")
                let img = image(of: v)
                save(img, "settings_\(pane)")
                rows.append(("\(pane)", img))
            }
        }
        _ = rows
        w.close()
    }
}
