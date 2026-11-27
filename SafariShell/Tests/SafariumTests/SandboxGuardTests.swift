import XCTest
@testable import Safarium

final class SandboxGuardTests: HermeticTestCase {
    func testHomeIsRedirectedToSandbox() {
        XCTAssertTrue(NSHomeDirectory().hasPrefix(Self.sandboxRoot.path))
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        XCTAssertTrue(appSup.hasPrefix(Self.sandboxRoot.path), "Application Support must resolve inside the sandbox, got \(appSup)")
    }

    /// Meta-test: every XCTestCase subclass in this target must derive from HermeticTestCase.
    func testAllTestClassesAreHermetic() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"^\s*(final\s+)?class\s+\w+\s*:\s*XCTestCase\b"#, options: [.anchorsMatchLines])
            let range = NSRange(text.startIndex..., in: text)
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                XCTFail("\(f.lastPathComponent): declares an XCTestCase subclass directly — inherit from HermeticTestCase instead")
            }
        }
    }
}
