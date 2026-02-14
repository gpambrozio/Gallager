import CoreGraphics
import Foundation
import ImageIO
import Logging

/// Result of comparing a screenshot against a baseline
public struct ComparisonResult: Sendable {
    /// Whether the comparison passed (within tolerance)
    public let passed: Bool
    /// Percentage of pixels that differ (0.0–100.0)
    public let diffPercentage: Double
    /// Path to the actual screenshot taken during the test
    public let actualPath: String
    /// Path to the baseline screenshot (may not exist if this is the first run)
    public let baselinePath: String
    /// Path to the diff image (nil if comparison passed or no baseline existed)
    public let diffPath: String?
    /// Whether a new baseline was created (no prior baseline existed)
    public let baselineCreated: Bool
}

/// Errors specific to screenshot comparison
public enum ScreenshotComparisonError: Error, LocalizedError {
    case failedToLoadImage(path: String)
    case sizeMismatch(actual: (Int, Int), baseline: (Int, Int))
    case failedToCreateContext
    case failedToWriteImage(path: String)

    public var errorDescription: String? {
        switch self {
        case let .failedToLoadImage(path):
            "Failed to load image: \(path)"
        case let .sizeMismatch(actual, baseline):
            "Image size mismatch: actual=\(actual.0)x\(actual.1), baseline=\(baseline.0)x\(baseline.1)"
        case .failedToCreateContext:
            "Failed to create bitmap context for comparison"
        case let .failedToWriteImage(path):
            "Failed to write image: \(path)"
        }
    }
}

/// Compares screenshots against stored baselines using pixel-by-pixel comparison
public enum ScreenshotComparator {
    private static let logger = Logger(label: "e2e.screenshot-comparator")

    /// Compare a screenshot at `actualPath` against a baseline.
    ///
    /// - If no baseline exists, the actual screenshot is stored as the new baseline.
    /// - If a baseline exists, a pixel-by-pixel comparison is performed.
    /// - A diff image is generated when the comparison fails.
    ///
    /// - Parameters:
    ///   - actualPath: Path to the screenshot just taken
    ///   - baselineDir: Directory where baselines are stored (organized by scenario)
    ///   - label: A descriptive label used as the filename for the baseline
    ///   - tolerance: Maximum allowed percentage of differing pixels (0.0–100.0)
    /// - Returns: A `ComparisonResult` describing the outcome
    public static func compare(
        actualPath: String,
        baselineDir: String,
        label: String,
        tolerance: Double = 0.0
    ) throws -> ComparisonResult {
        let fm = FileManager.default
        let baselinePath = "\(baselineDir)/\(label).png"
        let diffPath = "\(baselineDir)/\(label)_diff.png"

        // Ensure baseline directory exists
        try fm.createDirectory(atPath: baselineDir, withIntermediateDirectories: true)

        // Clean up stale diff images from prior runs
        if fm.fileExists(atPath: diffPath) {
            try? fm.removeItem(atPath: diffPath)
        }

        // If no baseline exists, store the current screenshot as the baseline
        guard fm.fileExists(atPath: baselinePath) else {
            logger.info("No baseline found for '\(label)'. Storing current screenshot as baseline.")
            try fm.copyItem(atPath: actualPath, toPath: baselinePath)
            return ComparisonResult(
                passed: true,
                diffPercentage: 0,
                actualPath: actualPath,
                baselinePath: baselinePath,
                diffPath: nil,
                baselineCreated: true
            )
        }

        // Load both images
        guard let actualImage = loadCGImage(from: actualPath) else {
            throw ScreenshotComparisonError.failedToLoadImage(path: actualPath)
        }
        guard let baselineImage = loadCGImage(from: baselinePath) else {
            throw ScreenshotComparisonError.failedToLoadImage(path: baselinePath)
        }

        // Verify sizes match
        let actualWidth = actualImage.width
        let actualHeight = actualImage.height
        let baselineWidth = baselineImage.width
        let baselineHeight = baselineImage.height

        guard actualWidth == baselineWidth, actualHeight == baselineHeight else {
            throw ScreenshotComparisonError.sizeMismatch(
                actual: (actualWidth, actualHeight),
                baseline: (baselineWidth, baselineHeight)
            )
        }

        // Perform pixel-by-pixel comparison
        let (diffPercentage, diffImage) = try comparePixels(
            actual: actualImage,
            baseline: baselineImage,
            width: actualWidth,
            height: actualHeight
        )

        let passed = diffPercentage <= tolerance

        let status = passed ? "PASSED" : "FAILED"
        let diffStr = String(format: "%.2f", diffPercentage)
        let tolStr = String(format: "%.2f", tolerance)
        logger.info("Screenshot '\(label)': \(diffStr)% diff (tolerance: \(tolStr)%) — \(status)")

        // Write diff image only when comparison fails
        var writtenDiffPath: String?
        if !passed, let diffImage {
            if writePNG(image: diffImage, to: diffPath) {
                writtenDiffPath = diffPath
                logger.info("Diff image saved: \(diffPath)")
            }
        }

        return ComparisonResult(
            passed: passed,
            diffPercentage: diffPercentage,
            actualPath: actualPath,
            baselinePath: baselinePath,
            diffPath: writtenDiffPath,
            baselineCreated: false
        )
    }

    // MARK: - Private

    /// Load a CGImage from a file path
    private static func loadCGImage(from path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Compare two images pixel-by-pixel, returning the diff percentage and an optional diff image.
    private static func comparePixels(
        actual: CGImage,
        baseline: CGImage,
        width: Int,
        height: Int
    ) throws -> (Double, CGImage?) {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalPixels = width * height

        // Create buffers for pixel data
        var actualPixels = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)
        var baselinePixels = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        // Render actual image into buffer
        guard let actualContext = CGContext(
            data: &actualPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ScreenshotComparisonError.failedToCreateContext
        }
        actualContext.draw(actual, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Render baseline image into buffer
        guard let baselineContext = CGContext(
            data: &baselinePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ScreenshotComparisonError.failedToCreateContext
        }
        baselineContext.draw(baseline, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Compare pixels and build diff image
        var diffPixels = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)
        var differingPixels = 0

        for i in 0 ..< totalPixels {
            let offset = i * bytesPerPixel
            let r1 = actualPixels[offset]
            let g1 = actualPixels[offset + 1]
            let b1 = actualPixels[offset + 2]
            let a1 = actualPixels[offset + 3]
            let r2 = baselinePixels[offset]
            let g2 = baselinePixels[offset + 1]
            let b2 = baselinePixels[offset + 2]
            let a2 = baselinePixels[offset + 3]

            if r1 != r2 || g1 != g2 || b1 != b2 || a1 != a2 {
                differingPixels += 1
                // Mark differing pixels in red
                diffPixels[offset] = 255     // R
                diffPixels[offset + 1] = 0   // G
                diffPixels[offset + 2] = 0   // B
                diffPixels[offset + 3] = 255 // A
            } else {
                // Dim matching pixels
                diffPixels[offset] = r1 / 3
                diffPixels[offset + 1] = g1 / 3
                diffPixels[offset + 2] = b1 / 3
                diffPixels[offset + 3] = 255
            }
        }

        let diffPercentage = (Double(differingPixels) / Double(totalPixels)) * 100.0

        // Only create the diff image if there are differences
        var diffImage: CGImage?
        if differingPixels > 0 {
            diffImage = diffPixels.withUnsafeMutableBufferPointer { buffer in
                guard let diffContext = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                ) else { return nil as CGImage? }
                return diffContext.makeImage()
            }
        }

        return (diffPercentage, diffImage)
    }

    /// Write a CGImage as a PNG file
    @discardableResult
    private static func writePNG(image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
