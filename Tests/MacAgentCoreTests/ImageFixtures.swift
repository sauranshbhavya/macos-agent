import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic images for the redaction and egress-encoder tests, and a pixel sampler to read them
/// back.
///
/// Shared between `LocalRedactionServiceTests` and `RedactedCaptureEncoderTests` rather than
/// duplicated: SONNY-114 added a second suite that needs exactly the same white/black/two-tone
/// fixtures, and two copies of a sampler whose Y convention is the thing being tested is two places
/// for the convention to drift.

enum ImageFixtures {
    static func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    static func png(from context: CGContext) -> Data {
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func solidWhitePNG(width: Int, height: Int) -> Data {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return png(from: ctx)
    }

    /// White top half, black bottom half — in *image* terms (what a human sees). Drawn via CG
    /// coordinates where y=0 is the bottom, so the black fill covers CG y 0..<height/2.
    static func whiteOverBlackPNG(width: Int, height: Int) -> Data {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return png(from: ctx)
    }

    /// Renders dark text lines on a white background. `topLeft` positions are in image space
    /// (top-left origin); the CoreText baseline is placed relative to them.
    static func renderedTextPNG(width: Int, height: Int, lines: [(text: String, topLeft: CGPoint)], fontSize: CGFloat = 32) -> Data {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        for line in lines {
            let attributes = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ] as CFDictionary
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, attributes)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // Convert the image-space top-left to a CG-space baseline: the baseline sits one
            // font-size below the top-left corner.
            ctx.textPosition = CGPoint(x: line.topLeft.x, y: CGFloat(height) - line.topLeft.y - fontSize)
            CTLineDraw(ctLine, ctx)
        }
        return png(from: ctx)
    }

    /// Samples one pixel, addressed in image space (x from the left, y from the top).
    static func rgb(inPNG data: Data, x: Int, yFromTop: Int) -> (r: Int, g: Int, b: Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (yFromTop * width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
    }

    static func isBlack(_ rgb: (r: Int, g: Int, b: Int)) -> Bool {
        rgb.r < 30 && rgb.g < 30 && rgb.b < 30
    }

    static func isWhite(_ rgb: (r: Int, g: Int, b: Int)) -> Bool {
        rgb.r > 225 && rgb.g > 225 && rgb.b > 225
    }
}

extension ImageFixtures {
    /// Deterministic uniform noise — the encoder's worst case, and the only fixture that reliably
    /// pushes a small image past a byte budget. Seeded xorshift rather than `Int.random` so a
    /// size assertion means the same thing on every run.
    static func uniformNoisePNG(width: Int, height: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
        let ctx = context(width: width, height: height)
        let buffer = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var state = seed
        for index in 0..<(ctx.bytesPerRow * height) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // Alpha stays opaque so the fixture's PNG and JPEG candidates describe one picture.
            buffer[index] = index % 4 == 3 ? 255 : UInt8(state & 0xFF)
        }
        return png(from: ctx)
    }

    /// Deterministic noise with a pure-white block planted in it, positioned in image space
    /// (top-left origin).
    ///
    /// The one fixture that reaches the *lossy* branch while carrying something to redact: noise is
    /// what makes JPEG the smaller encoding, and white on noise is the highest-contrast thing that
    /// could survive a paint that failed.
    static func noiseWithWhiteBlockPNG(width: Int, height: Int, block: CGRect) -> Data {
        let noise = uniformNoisePNG(width: width, height: height)
        let ctx = context(width: width, height: height)
        ctx.draw(decoded(noise), in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(
            x: block.minX,
            y: CGFloat(height) - block.maxY,
            width: block.width,
            height: block.height
        ))
        return png(from: ctx)
    }

    /// A pure-red block on white, positioned in image space (top-left origin).
    ///
    /// Red is the tracer for the resample-after-redaction ordering test: the pipeline paints the
    /// block opaque black, so a correctly ordered payload is black and white and every blend between
    /// them is grey. Any red left anywhere is a pixel that carried the block's colour *through* a
    /// resample, which is only possible if the resample ran first.
    static func redBlockOnWhitePNG(width: Int, height: Int, block: CGRect) -> Data {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(
            x: block.minX,
            y: CGFloat(height) - block.maxY,
            width: block.width,
            height: block.height
        ))
        return png(from: ctx)
    }

    static func decoded(_ data: Data) -> CGImage {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    /// The brightest channel value anywhere inside a region, addressed in image space (x from the
    /// left, y from the top).
    ///
    /// Reads every pixel in the region rather than sampling a grid, because the question it answers —
    /// "is any of what was underneath still showing" — is a question about the worst pixel, and a
    /// sample that missed it would answer the wrong one. Clamped to the image, so a caller may pass a
    /// region in the *source's* coordinates against a resampled payload and get a meaningful answer
    /// for the overlap.
    static func maximumChannel(inImageData data: Data, region: CGRect) -> Int {
        let image = decoded(data)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = region.intersection(bounds)
        guard !clamped.isNull, !clamped.isEmpty else { return 0 }

        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: bounds)

        var maximum = 0
        for y in Int(clamped.minY)..<Int(clamped.maxY) {
            for x in Int(clamped.minX)..<Int(clamped.maxX) {
                let offset = (y * image.width + x) * 4
                maximum = max(maximum, Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
            }
        }
        return maximum
    }

    /// Every pixel's red dominance — how far red exceeds the larger of green and blue, which is 0
    /// for anything black, white or grey. Returned as the maximum over the whole image.
    static func maximumRedDominance(inImageData data: Data) -> Int {
        let image = decoded(data)
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var maximum = 0
        for offset in stride(from: 0, to: buffer.count, by: 4) {
            let dominance = Int(buffer[offset]) - max(Int(buffer[offset + 1]), Int(buffer[offset + 2]))
            maximum = max(maximum, dominance)
        }
        return maximum
    }
}
