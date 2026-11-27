import XCTest
import AppKit
@testable import Safarium

// Shared helpers for the UI suites (SettingsWindowTests, CustomizeToolbarTests, ExtensionsToolbarTests,
// GlassToolbarControlsTests, PopoverControllersTests). Everything here is offscreen: no window is ever ordered
// on screen and no popover is ever shown.

/// Reads a private stored property of a live object by name (read-only, no visibility change needed).
func uiPrivate<T>(_ object: Any, _ label: String, as type: T.Type = T.self) -> T? {
    Mirror(reflecting: object).children.first(where: { $0.label == label })?.value as? T
}

/// Snapshot / clean / restore of every `Safarium.*` key in `UserDefaults.standard`.
/// `setUp` captures the user's keys, clears them so each test starts from defaults; `tearDown` restores.
enum UIDefaultsSandbox {
    static let prefix = "Safarium."

    static func snapshot() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }
    }

    static func clear() {
        let ud = UserDefaults.standard
        for key in ud.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            ud.removeObject(forKey: key)
        }
    }

    static func restore(_ values: [String: Any]) {
        clear()
        let ud = UserDefaults.standard
        for (key, value) in values {
            ud.set(value, forKey: key)
        }
    }
}

/// Offscreen host window. Never ordered on screen; closed by the caller.
@MainActor
func uiHostWindow(size: NSSize) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    return w
}

/// Recursively collects subviews of the given class.
@MainActor
func uiDescendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    var out: [T] = []
    for sub in root.subviews {
        if let typed = sub as? T { out.append(typed) }
        out.append(contentsOf: uiDescendants(of: sub, as: type))
    }
    return out
}

/// All visible text (labels and text fields) under a view, in tree order.
@MainActor
func uiAllStrings(in root: NSView) -> [String] {
    var out: [String] = []
    for sub in root.subviews {
        if let tf = sub as? NSTextField { out.append(tf.stringValue) }
        if let btn = sub as? NSButton { out.append(btn.title) }
        out.append(contentsOf: uiAllStrings(in: sub))
    }
    return out
}

/// Builds a synthetic key-down event for the given hardware key code.
func uiKeyEvent(_ keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}

/// A `BrowserExtensionItem` with sensible defaults for layout tests.
func uiExtension(
    _ id: String,
    name: String? = nil,
    enabled: Bool = true,
    storeID: String? = nil,
    installPath: String = ""
) -> BrowserExtensionItem {
    BrowserExtensionItem(
        id: id,
        storeID: storeID,
        name: name ?? id.uppercased(),
        version: "1.0",
        installPath: installPath,
        icon: nil,
        badgeText: nil,
        badgeColor: nil,
        popupURL: nil,
        enabled: enabled
    )
}

/// Writes `files` (relative path -> JSON-able object) under a fresh directory inside the sandbox home.
func uiWriteExtensionFixture(_ files: [String: Any], name: String = UUID().uuidString) throws -> String {
    let root = HermeticTestCase.sandboxRoot.appendingPathComponent("ext-fixtures/\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (rel, object) in files {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text = object as? String {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: url)
        }
    }
    return root.path
}
