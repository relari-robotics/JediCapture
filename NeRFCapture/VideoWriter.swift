//
//  VideoWriter.swift
//  JediCapture
//
//  Disk-efficient encoders for the recorded streams:
//   - RGB  → HEVC video (AVAssetWriter), ~2 orders of magnitude smaller than
//            PNG-per-frame. Frames carry their device-clock presentation time,
//            so video frame i ↔ frames.json[i] ↔ imu.csv align by timestamp.
//   - Depth→ lossless 16-bit grayscale PNG in millimeters (value * 0.001 = m).
//            256x192 LiDAR maps are tiny, so lossless is cheap and metric scale
//            is preserved exactly (unlike NeRFCapture's Float32→UIImage path).
//

import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false
    private(set) var appended = 0
    private(set) var dropped = 0

    init?(url: URL, width: Int, height: Int) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            print("[video] could not create AVAssetWriter at \(url.path)")
            return nil
        }
        writer = w
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
    }

    /// Append one frame at its device-clock time. Returns false if the encoder
    /// wasn't ready (frame dropped) — counted, never fatal.
    @discardableResult
    func append(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) -> Bool {
        let t = CMTime(seconds: time, preferredTimescale: 1_000_000)
        if !sessionStarted {
            guard writer.startWriting() else {
                print("[video] startWriting failed: \(String(describing: writer.error))")
                return false
            }
            writer.startSession(atSourceTime: t)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { dropped += 1; return false }
        if adaptor.append(pixelBuffer, withPresentationTime: t) {
            appended += 1
            return true
        }
        dropped += 1
        return false
    }

    func finish(completion: @escaping () -> Void) {
        guard sessionStarted else { completion(); return }
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }
}

/// Copy an ARKit Float32 depth map (meters) out to a UInt16 millimeter buffer.
/// Run this synchronously on the capture thread (the ARFrame owns the pixel
/// buffer only briefly); encode the result with `writeDepth16PNG` off-thread.
/// Non-finite samples (no return) become 0.
func extractDepthMillimeters(_ depthMap: CVPixelBuffer) -> (px: [UInt16], w: Int, h: Int) {
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
    let w = CVPixelBufferGetWidth(depthMap)
    let h = CVPixelBufferGetHeight(depthMap)
    let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
    var px = [UInt16](repeating: 0, count: w * h)
    guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return (px, w, h) }
    for y in 0..<h {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
        for x in 0..<w {
            let mm = (row[x] * 1000.0).rounded()
            px[y * w + x] = mm.isFinite ? UInt16(max(0, min(65535, mm))) : 0
        }
    }
    return (px, w, h)
}

/// Write a millimeter UInt16 buffer as a lossless 16-bit grayscale PNG.
func writeDepth16PNG(_ px: [UInt16], w: Int, h: Int, to url: URL) {
    let data = px.withUnsafeBytes { Data($0) }
    // 16-bit gray, little-endian to match the native UInt16 buffer; ImageIO
    // re-encodes to PNG's big-endian on write.
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        .union(.byteOrder16Little)
    guard let provider = CGDataProvider(data: data as CFData),
          let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16,
                           bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        print("[depth] failed to encode \(url.lastPathComponent)")
        return
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}
