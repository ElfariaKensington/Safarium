import XCTest
import AppKit
@testable import Safarium

/// Pure helpers of `DownloadAnimationController`: on-disk staging detection, Dock stack lookup,
/// Dock Downloads geometry fallback and the flight easing curve. Files live in the hermetic sandbox.
final class DownloadAnimationTests: HermeticTestCase {

    nonisolated(unsafe) private var workDir: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DownloadAnimationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        super.tearDown()
    }

    private func item(path: String?, id: UInt32 = 1) -> BrowserDownloadItem {
        BrowserDownloadItem(id: id, suggestedFileName: "file.bin", fullPath: path, url: nil,
                            totalBytes: 100, receivedBytes: 10, percentComplete: 10,
                            isInProgress: true, isComplete: false, isCanceled: false, isPaused: false)
    }

    @discardableResult
    private func touch(_ name: String, created: Date? = nil) -> String {
        let url = workDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
        return url.path
    }

    // MARK: On-disk progress file detection

    func testPrefersCrdownloadCandidateOverFinalPath() {
        let target = touch("movie.mp4")
        let partial = touch("movie.mp4.crdownload")
        let found = DownloadAnimationController.onDiskProgressURL(for: item(path: target), since: 0)
        XCTAssertEqual(found?.path, partial)
    }

    func testFallsBackToDownloadSuffixThenFinalPath() {
        let target = workDir.appendingPathComponent("archive.zip").path
        let dl = touch("archive.zip.download")
        XCTAssertEqual(DownloadAnimationController.onDiskProgressURL(for: item(path: target), since: 0)?.path, dl)
        try? FileManager.default.removeItem(atPath: dl)
        let final = touch("archive.zip")
        XCTAssertEqual(DownloadAnimationController.onDiskProgressURL(for: item(path: final), since: 0)?.path, final)
    }

    func testNilOrEmptyPathReturnsNil() {
        XCTAssertNil(DownloadAnimationController.onDiskProgressURL(for: item(path: nil), since: 0))
        XCTAssertNil(DownloadAnimationController.onDiskProgressURL(for: item(path: ""), since: 0))
    }

    func testMissingFilesReturnNil() {
        let target = workDir.appendingPathComponent("never-written.bin").path
        XCTAssertNil(DownloadAnimationController.onDiskProgressURL(for: item(path: target), since: 0))
    }

    func testUnconfirmedStagingFileIsDetectedWhenCreatedAfterStart() {
        let start = Date()
        let target = workDir.appendingPathComponent("final.dmg").path
        let staged = touch("Unconfirmed 1234.crdownload", created: start.addingTimeInterval(1))
        let found = DownloadAnimationController.onDiskProgressURL(for: item(path: target),
                                                                  since: start.timeIntervalSinceReferenceDate)
        XCTAssertEqual(found?.path, staged)
    }

    func testStaleUnconfirmedFileIsIgnored() {
        let start = Date()
        let target = workDir.appendingPathComponent("final.dmg").path
        touch("Unconfirmed 999.crdownload", created: start.addingTimeInterval(-60))
        XCTAssertNil(DownloadAnimationController.onDiskProgressURL(for: item(path: target),
                                                                  since: start.timeIntervalSinceReferenceDate))
    }

    func testUnconfirmedFileWithinTwoSecondGraceIsAccepted() {
        let start = Date()
        let target = workDir.appendingPathComponent("final.dmg").path
        let staged = touch("Unconfirmed 5.crdownload", created: start.addingTimeInterval(-1.5))
        let found = DownloadAnimationController.onDiskProgressURL(for: item(path: target),
                                                                  since: start.timeIntervalSinceReferenceDate)
        XCTAssertEqual(found?.path, staged, "files up to 2 s before the start are still accepted")
    }

    func testNewestUnconfirmedFileWins() {
        let start = Date()
        let target = workDir.appendingPathComponent("final.dmg").path
        touch("Unconfirmed 1.crdownload", created: start.addingTimeInterval(1))
        let newest = touch("Unconfirmed 2.crdownload", created: start.addingTimeInterval(5))
        let found = DownloadAnimationController.onDiskProgressURL(for: item(path: target),
                                                                  since: start.timeIntervalSinceReferenceDate)
        XCTAssertEqual(found?.path, newest)
    }

    func testUnrelatedNamesAreNotStagingFiles() {
        let start = Date()
        let target = workDir.appendingPathComponent("final.dmg").path
        touch("Other 1.crdownload", created: start.addingTimeInterval(1))
        touch("Unconfirmed 1.part", created: start.addingTimeInterval(1))
        XCTAssertNil(DownloadAnimationController.onDiskProgressURL(for: item(path: target),
                                                                  since: start.timeIntervalSinceReferenceDate))
    }

    // MARK: Dock stack detection (sandboxed prefs are empty, so the Downloads fallback applies)

    func testDockStackFallbackRejectsOtherFolders() {
        let other = workDir.appendingPathComponent("NotInDock", isDirectory: true)
        XCTAssertFalse(DownloadAnimationController.dockStackContains(folder: other))
    }

    // MARK: Flight easing

    func testCubicBezierEaseHitsEndpoints() {
        XCTAssertEqual(DownloadAnimationController.cubicBezierEase(0, 0.425, 0.025, 0.575, 0.925), 0, accuracy: 1e-6)
        XCTAssertEqual(DownloadAnimationController.cubicBezierEase(1, 0.425, 0.025, 0.575, 0.925), 1, accuracy: 1e-6)
    }

    func testCubicBezierEaseMidpointMatchesClosedForm() {
        // x(0.5) = 0.5 and y(0.5) = 3*0.5*0.25*0.025 + 3*0.25*0.5*0.925 + 0.125 = 0.48125
        XCTAssertEqual(DownloadAnimationController.cubicBezierEase(0.5, 0.425, 0.025, 0.575, 0.925), 0.48125, accuracy: 1e-4)
    }

    func testCubicBezierEaseMatchesLinearCurve() {
        for t in stride(from: 0.0, through: 1.0, by: 0.125) {
            XCTAssertEqual(DownloadAnimationController.cubicBezierEase(t, 0, 0, 1, 1), t, accuracy: 1e-5)
        }
    }

    func testCubicBezierEaseIsMonotonicForFlightCurve() {
        var previous = -1.0
        for i in 0...100 {
            let v = DownloadAnimationController.cubicBezierEase(Double(i) / 100, 0.425, 0.025, 0.575, 0.925)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-6)
            previous = v
        }
    }

    // MARK: Dock Downloads geometry fallback

    func testDockDownloadsTargetStaysInsideScreenAndTileIsClamped() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let controller = DownloadAnimationController()
        let target = controller.dockDownloadsTarget(on: screen)
        XCTAssertGreaterThanOrEqual(target.tile, 32)
        XCTAssertLessThanOrEqual(target.tile, 96)
        XCTAssertTrue(screen.frame.contains(target.point), "dock target \(target.point) must lie on its screen")
    }
}
