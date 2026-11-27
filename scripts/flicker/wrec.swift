// wrec <windowID> <seconds> <outdir> [width]  — records one window (even occluded) via ScreenCaptureKit at display rate.
import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let widArg = args[1]
let secs = Double(args[2])!
let outDir = args[3]
let outW = args.count > 4 ? Int(args[4])! : 560
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

final class Out: NSObject, SCStreamOutput {
    var frames: [(Double, CGImage)] = []
    let ctx = CIContext()
    var t0: Double = -1
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        if let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let st = att[.status] as? Int, st != SCFrameStatus.complete.rawValue { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if t0 < 0 { t0 = t }
        let ci = CIImage(cvPixelBuffer: pb)
        let sc = CGFloat(outW) / ci.extent.width
        let small = ci.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        if let cg = ctx.createCGImage(small, from: small.extent) { frames.append((t - t0, cg)) }
    }
}

let sem = DispatchSemaphore(value: 0)
let out = Out()
var streamRef: SCStream?
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let cands = content.windows.filter { w in
        if let n = UInt32(widArg) { return w.windowID == n }
        return w.owningApplication?.applicationName == widArg && w.windowLayer == 0 && w.frame.width > 300
    }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    guard let w = cands.first else { print("no window"); exit(1) }
    let filter = SCContentFilter(desktopIndependentWindow: w)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    cfg.queueDepth = 8
    cfg.showsCursor = false
    let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
    try await s.startCapture()
    streamRef = s
    print("REC_STARTED"); fflush(stdout)
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    try await s.stopCapture()
    sem.signal()
}
sem.wait()
var log = ""
for (i, (t, img)) in out.frames.enumerated() {
    let url = URL(fileURLWithPath: String(format: "%@/f_%04d.png", outDir, i))
    if let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
    log += String(format: "%d %.4f\n", i, t)
}
try? log.write(toFile: outDir + "/times.txt", atomically: true, encoding: .utf8)
try? String(format: "%.4f", out.t0).write(toFile: outDir + "/t0.txt", atomically: true, encoding: .utf8)
print("frames:", out.frames.count)
