import AppKit
import CoreImage
import ScreenCaptureKit

/// Collects the frames ScreenCaptureKit delivers for one window: only complete frames, i.e. the ones that changed.
final class Recorder: NSObject, SCStreamOutput {
    struct Frame { let image: CGImage?; let t: Double; let px: [[Int]] }
    private(set) var frames: [Frame] = []
    private var t0: Double = 0
    private let ctx = CIContext()
    /// sample points in the picture's pixels
    let points: [CGPoint]
    let keepImages: Bool
    private let lock = NSLock()

    init(points: [CGPoint], keepImages: Bool) {
        self.points = points
        self.keepImages = keepImages
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        let now = CACurrentMediaTime()
        let px = sample(pb)
        var image: CGImage?
        if keepImages {
            let ci = CIImage(cvPixelBuffer: pb)
            image = ctx.createCGImage(ci, from: ci.extent)
        }
        lock.lock()
        if t0 == 0 { t0 = now }
        frames.append(Frame(image: image, t: (now - t0) * 1000, px: px))
        lock.unlock()
    }

    /// [r, g, b] at each point (BGRA buffer)
    private func sample(_ pb: CVPixelBuffer) -> [[Int]] {
        guard !points.isEmpty else { return [] }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return points.map { p in
            let x = min(max(Int(p.x), 0), w - 1), y = min(max(Int(p.y), 0), h - 1)
            let o = y * row + x * 4
            return [Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o])]
        }
    }

    func snapshot() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
