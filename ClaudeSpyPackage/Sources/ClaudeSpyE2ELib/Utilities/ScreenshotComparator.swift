import CoreImage
import Foundation
import Logging

/// Result of comparing a screenshot against a baseline
public struct ComparisonResult: Sendable {
    /// Whether the comparison passed (within tolerance)
    public let passed: Bool
    /// Percentage of pixels that differ (0–100)
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
    case failedToWriteImage(path: String)

    public var errorDescription: String? {
        switch self {
        case let .failedToLoadImage(path):
            "Failed to load image: \(path)"
        case let .sizeMismatch(actual, baseline):
            "Image size mismatch: actual=\(actual.0)x\(actual.1), baseline=\(baseline.0)x\(baseline.1)"
        case let .failedToWriteImage(path):
            "Failed to write image: \(path)"
        }
    }
}

/// Compares screenshots against stored baselines using Core Image filters.
///
/// Uses `CIDifferenceBlendMode` for per-pixel difference, `CIMaximumComponent`
/// + `CIColorThreshold` for binary differing-pixel detection, and `CIAreaAverage`
/// to compute the diff percentage — all GPU-accelerated via Core Image.
public enum ScreenshotComparator {
    private static let logger = Logger(label: "e2e.screenshot-comparator")

    /// Compare a screenshot at `actualPath` against a baseline.
    ///
    /// - If no baseline exists, the actual screenshot is stored as the new baseline.
    /// - If a baseline exists, comparison is performed using Core Image filters.
    /// - A diff image is generated when the comparison fails.
    ///
    /// - Parameters:
    ///   - actualPath: Path to the screenshot just taken
    ///   - baselineDir: Directory where baselines are stored (organized by scenario)
    ///   - label: A descriptive label used as the filename for the baseline
    ///   - tolerance: Maximum allowed percentage of differing pixels (0–100)
    ///   - perPixelThreshold: Minimum per-pixel difference (0–1) to count as changed.
    ///     Defaults to 0.02 (~5/255) which ignores sub-pixel anti-aliasing.
    /// - Returns: A `ComparisonResult` describing the outcome
    public static func compare(
        actualPath: String,
        baselineDir: String,
        label: String,
        tolerance: Double = 0,
        perPixelThreshold: Double = 0.02
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
        let actualURL = URL(fileURLWithPath: actualPath)
        let baselineURL = URL(fileURLWithPath: baselinePath)

        guard let actualImage = CIImage(contentsOf: actualURL) else {
            throw ScreenshotComparisonError.failedToLoadImage(path: actualPath)
        }
        guard let baselineImage = CIImage(contentsOf: baselineURL) else {
            throw ScreenshotComparisonError.failedToLoadImage(path: baselinePath)
        }

        // Verify sizes match
        let actualSize = actualImage.extent.size
        let baselineSize = baselineImage.extent.size

        guard actualSize == baselineSize else {
            throw ScreenshotComparisonError.sizeMismatch(
                actual: (Int(actualSize.width), Int(actualSize.height)),
                baseline: (Int(baselineSize.width), Int(baselineSize.height))
            )
        }

        // Compare using Core Image filter pipeline
        let (diffPercentage, diffImage) = computeDiff(
            actual: actualImage,
            baseline: baselineImage,
            perPixelThreshold: perPixelThreshold
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

    /// Compare two images using Core Image filters, returning the diff percentage
    /// and an optional composite diff image (red = different, full brightness = matching).
    private static func computeDiff(
        actual: CIImage,
        baseline: CIImage,
        perPixelThreshold: Double
    ) -> (Double, CIImage?) {
        let extent = actual.extent

        // 1. Per-pixel absolute difference (identical pixels → black)
        let difference = actual.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: baseline,
        ])

        // 2. Grayscale: max(R, G, B) per pixel so any channel difference is captured
        let grayscale = difference.applyingFilter("CIMaximumComponent")

        // 3. Binary mask: differences above threshold → white, otherwise black
        let binary = grayscale.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": perPixelThreshold as NSNumber,
        ])

        // 4. Average of binary image = fraction of differing pixels
        let average = binary.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])

        // Read the 1×1 average pixel
        let context = CIContext()
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        let diffPercentage = Double(pixel[0]) * 100

        guard diffPercentage > 0 else { return (0, nil) }

        // 5. Composite diff image: actual image at full brightness with semi-transparent
        //    red overlay only on differing pixels
        let redTint = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            .cropped(to: extent)
        let tinted = redTint.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: actual,
        ])

        // Where mask is white (different) → show red-tinted actual
        // Where mask is black (matching) → show actual at full brightness
        let composited = tinted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: actual,
            kCIInputMaskImageKey: binary,
        ])

        return (diffPercentage, composited)
    }

    /// Write a CIImage as a PNG file
    @discardableResult
    private static func writePNG(image: CIImage, to path: String) -> Bool {
        let context = CIContext()
        let url = URL(fileURLWithPath: path)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        do {
            try context.writePNGRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace
            )
            return true
        } catch {
            logger.warning("Failed to write diff image: \(error.localizedDescription)")
            return false
        }
    }
}
