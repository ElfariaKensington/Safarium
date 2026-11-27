import XCTest
import AppKit
@testable import Safarium

/// The window used to log "Unable to simultaneously satisfy constraints" at every launch (zero-width vertical tab rail
/// and zero-width glass clusters against fixed-width children). Required constraints must now be satisfiable.
@MainActor
final class ConstraintConflictTests: HermeticTestCase {
    func testWindowHierarchyHasNoRequiredWidthConflictsWithCollapsedClusters() {
        _ = NSApplication.shared
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let w = wc.window!
        w.contentView?.layoutSubtreeIfNeeded()
        var offenders: [String] = []
        func walk(_ v: NSView) {
            for c in v.constraints where c.isActive && c.priority == .required && c.firstAttribute == .width && c.secondItem == nil && c.constant > 0 {
                if let cluster = v.superview as? GlassToolbarClusterView, cluster.constraints.contains(where: { $0.firstAttribute == .width && $0.constant == 0 && $0.priority == .required }) {
                    offenders.append("\(type(of: v)) width==\(c.constant) inside collapsed \(type(of: cluster))")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(w.contentView!)
        XCTAssertTrue(offenders.isEmpty, "\(offenders)")
        w.close()
    }
}
