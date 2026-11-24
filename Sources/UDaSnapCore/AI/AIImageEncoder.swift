import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes screenshots as data URLs accepted by OpenAI-compatible vision endpoints.
/// Uses Core Graphics/ImageIO only so the encoder stays testable outside AppKit.
package enum AIImageEncoder {
    package static func screenshotDataURL(_ image: CGImage) -> String? {
        if let png = encode(image, as: .png), png.count <= 8_000_000 {
            return dataURL(png, mime: "image/png")
        }

        guard let scaled = scaledImage(image, maxPixel: 4096),
            let jpeg = encode(scaled, as: .jpeg, quality: 0.9)
        else {
            return nil
        }
        return dataURL(jpeg, mime: "image/jpeg")
    }

    package static func testImageDataURL() -> String? {
        let width = 320
        let height = 96
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            "UDaSnap TEST 2026" as CFString,
            attributes as CFDictionary
        )
        guard let attributed else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 18, y: 30)
        CTLineDraw(line, context)

        guard let image = context.makeImage(),
            let png = encode(image, as: .png)
        else {
            return nil
        }
        return dataURL(png, mime: "image/png")
    }

    private static func pngData(_ image: CGImage) -> Data? {
        encode(image, as: .png)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func scaledImage(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxPixel) / CGFloat(longest))
        let newWidth = max(1, Int(CGFloat(width) * scale))
        let newHeight = max(1, Int(CGFloat(height) * scale))

        guard
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private static func dataURL(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
