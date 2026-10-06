import Foundation
import CoreVideo

/// Deterministic test pattern: a moving box, plus the frame index stamped as 16 black/white blocks
/// across the top so a receiver can read which frame it decoded (used for latency measurement).
enum DemoPattern {
    static let width = 1280
    static let height = 720
    static let bits = 16
    static let block = 64  // px; large enough to survive H.264 at low bitrates

    static func makePool() -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }

    static func frame(_ index: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { return nil }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        // Row-wise memsets keep this cheap enough for 30 fps even in unoptimized debug builds.
        let boxX = (index * 8) % width
        for y in 0..<height {
            let row = luma + y * lumaStride
            if y < block {
                for bit in 0..<bits {
                    memset(row + bit * block, (index >> (bits - 1 - bit)) & 1 == 1 ? 235 : 16, block)
                }
                memset(row + bits * block, 16, width - bits * block)
            } else {
                memset(row, Int32(40 + y * 120 / height), width)
                if abs(y - height / 2) < 90 {
                    let start = max(0, boxX - 60)
                    memset(row + start, 230, min(width, boxX + 60) - start)
                }
            }
        }
        for y in 0..<(height / 2) {
            let row = chroma + y * chromaStride
            if y * 2 < block { memset(row, 128, width); continue }
            for x in stride(from: 0, to: width, by: 2) {
                row[x] = UInt8(90 + x * 60 / width)
                row[x + 1] = 150
            }
        }
        return pixel
    }

    /// Reads the stamped index from a decoded luma plane (any resolution with the same aspect).
    static func readIndex(luma: UnsafePointer<UInt8>, stride: Int, width frameWidth: Int) -> Int {
        let scale = Double(frameWidth) / Double(width)
        let y = Int(Double(block / 2) * scale)
        var value = 0
        for bit in 0..<bits {
            let x = Int((Double(bit * block) + Double(block) / 2) * scale)
            value = value << 1 | (luma[y * stride + x] > 128 ? 1 : 0)
        }
        return value
    }

    /// 10 ms of a 440 Hz tone at mono 48 kHz starting at `sample`.
    static func tone(startingAt sample: Int, count: Int = PCMAudioDevice.chunk) -> [Int16] {
        (0..<count).map { Int16(sin(Double(sample + $0) * 440 * 2 * .pi / 48_000) * 6_000) }
    }
}
