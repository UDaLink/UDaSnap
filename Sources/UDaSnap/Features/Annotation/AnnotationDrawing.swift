import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UDaSnapCore

extension AnnotationColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

@MainActor
enum AnnotationTextMetrics {
    static func font(size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.systemFont(ofSize: max(6, size), weight: weight)
    }

    static func attributes(for style: AnnotationStyle, contentScale: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        return [
            .font: font(size: style.fontSize * contentScale),
            .foregroundColor: style.color.nsColor,
            .paragraphStyle: paragraph,
        ]
    }

    static func size(for text: String, style: AnnotationStyle, contentScale: CGFloat, maxWidth: CGFloat? = nil)
        -> CGSize
    {
        guard !text.isEmpty else { return CGSize(width: 8, height: style.fontSize * contentScale) }
        let attributes = attributes(for: style, contentScale: contentScale)
        let limit = maxWidth ?? (480 * contentScale)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: limit, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return CGSize(
            width: ceil(rect.width) + 8 * contentScale,
            height: ceil(rect.height) + 6 * contentScale)
    }
}

@MainActor
enum AnnotationPainter {
    static func draw(
        document: AnnotationDocument,
        zoom: CGFloat,
        selectionID: UUID? = nil,
        draft: AnnotationObject? = nil,
        editingTextID: UUID? = nil,
        cropRect: CGRect? = nil,
        cropActive: Bool = false
    ) {
        let w = CGFloat(document.image.width)
        let h = CGFloat(document.image.height)
        let base = NSImage(cgImage: document.image, size: NSSize(width: w, height: h))
        base.draw(
            in: NSRect(x: 0, y: 0, width: w, height: h),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        for object in document.objects where object.id != editingTextID {
            draw(object, baseImage: document.image, contentScale: document.contentScale)
        }
        if let draft {
            draw(draft, baseImage: document.image, contentScale: document.contentScale)
        }
        if let selectionID, let index = document.objects.firstIndex(where: { $0.id == selectionID }) {
            drawSelection(document.objects[index], zoom: zoom)
        }
        if cropActive, let cropRect {
            drawCropOverlay(cropRect, in: CGRect(x: 0, y: 0, width: w, height: h), zoom: zoom)
        }
    }

    private static func draw(_ object: AnnotationObject, baseImage: CGImage, contentScale: CGFloat) {
        let scale = contentScale
        let color = object.style.color.nsColor
        let lineWidth = max(1, object.style.lineWidth * scale)
        let frame = object.frame.standardized
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch object.kind {
        case .rectangle:
            let path = NSBezierPath(rect: frame)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: frame)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case .line(let start, let end):
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()

        case .arrow(let start, let end):
            drawArrow(start: start, end: end, color: color, lineWidth: lineWidth, scale: scale)

        case .text(let text):
            guard !text.isEmpty else { break }
            let attributed = NSAttributedString(
                string: text,
                attributes: AnnotationTextMetrics.attributes(for: object.style, contentScale: scale))
            attributed.draw(
                with: frame,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil)

        case .number(let value):
            let diameter = min(frame.width, frame.height)
            let circleRect = CGRect(
                x: frame.midX - diameter / 2,
                y: frame.midY - diameter / 2,
                width: diameter,
                height: diameter)
            let path = NSBezierPath(ovalIn: circleRect)
            color.setFill()
            path.fill()
            let numberFont = AnnotationTextMetrics.font(
                size: diameter * 0.52, weight: .bold)
            let string = "\(value)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor.white,
            ]
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(
                    x: circleRect.midX - size.width / 2,
                    y: circleRect.midY - size.height / 2),
                withAttributes: attributes)

        case .pen(let points):
            drawFreehand(points, color: color, width: lineWidth)

        case .highlighter(let points):
            drawFreehand(
                points,
                color: NSColor.systemYellow.withAlphaComponent(0.36),
                width: max(4, lineWidth * 3))

        case .mosaic, .blur, .solid:
            if case .solid = object.kind {
                NSColor.black.setFill()
                NSBezierPath(rect: frame).fill()
            } else if let redacted = AnnotationRedactionRenderer.image(
                base: baseImage, rect: frame, mode: object.kind)
            {
                redacted.draw(
                    in: frame,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
            } else {
                NSColor.black.setFill()
                NSBezierPath(rect: frame).fill()
            }
        }
    }

    private static func drawArrow(
        start: CGPoint,
        end: CGPoint,
        color: NSColor,
        lineWidth: CGFloat,
        scale: CGFloat
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)
        let headLength = max(10 * scale, lineWidth * 2.4)
        let headHalfWidth = headLength * 0.42
        let base = CGPoint(
            x: end.x - cos(angle) * headLength,
            y: end.y - sin(angle) * headLength)
        let perpendicular = CGVector(dx: -sin(angle), dy: cos(angle))

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: base)
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(
            to: CGPoint(
                x: base.x + perpendicular.dx * headHalfWidth,
                y: base.y + perpendicular.dy * headHalfWidth))
        head.line(
            to: CGPoint(
                x: base.x - perpendicular.dx * headHalfWidth,
                y: base.y - perpendicular.dy * headHalfWidth))
        head.close()
        color.setFill()
        head.fill()
    }

    private static func drawFreehand(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func drawSelection(_ object: AnnotationObject, zoom: CGFloat) {
        let frame = object.frame.standardized
        let lineWidth = 1 / max(zoom, 0.01)
        let handleSize = 7 / max(zoom, 0.01)
        let border = NSBezierPath(rect: frame)
        border.lineWidth = lineWidth
        border.setLineDash([4 / max(zoom, 0.01), 3 / max(zoom, 0.01)], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        let points = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.midX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.midY),
        ]
        for point in points {
            let rect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize)
            let handle = NSBezierPath(rect: rect)
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.lineWidth = lineWidth
            handle.stroke()
        }
    }

    private static func drawCropOverlay(_ crop: CGRect, in bounds: CGRect, zoom: CGFloat) {
        let rect = crop.standardized.intersection(bounds)
        guard rect.width > 0, rect.height > 0 else { return }
        let shade = NSColor.black.withAlphaComponent(0.38)
        shade.setFill()
        let outside = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect.minY - bounds.minY),
            CGRect(x: bounds.minX, y: rect.maxY, width: bounds.width, height: bounds.maxY - rect.maxY),
            CGRect(x: bounds.minX, y: rect.minY, width: rect.minX - bounds.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY, width: bounds.maxX - rect.maxX, height: rect.height),
        ]
        for piece in outside where piece.width > 0 && piece.height > 0 {
            NSBezierPath(rect: piece).fill()
        }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2 / max(zoom, 0.01)
        NSColor.systemYellow.setStroke()
        border.stroke()
    }

    static func render(_ document: AnnotationDocument) -> CGImage? {
        let width = Int(document.canvasSize.width)
        let height = Int(document.canvasSize.height)
        guard width > 0, height > 0 else { return nil }
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let data = rep.bitmapData,
            let context = CGContext(
                data: data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rep.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        rep.size = NSSize(width: width, height: height)

        let previous = NSGraphicsContext.current
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphics
        context.setShouldAntialias(true)
        draw(document: document, zoom: 1)
        NSGraphicsContext.current = previous
        guard let rendered = rep.cgImage else { return nil }

        // NSBitmapImageRep 在翻转的 NSGraphicsContext 中绘制后，cgImage 的行序会上下颠倒。
        // 再做一次垂直翻转，保证导出的 PNG 与编辑器画布方向一致。
        guard
            let output = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return rendered }
        output.translateBy(x: 0, y: CGFloat(height))
        output.scaleBy(x: 1, y: -1)
        output.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        return output.makeImage()
    }
}

@MainActor
enum AnnotationRedactionRenderer {
    static func image(base: CGImage, rect: CGRect, mode: AnnotationKind) -> NSImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let source = CIImage(cgImage: base)
        let height = CGFloat(base.height)
        let ciRect = CGRect(
            x: rect.minX,
            y: height - rect.maxY,
            width: rect.width,
            height: rect.height)
        let cropped = source.cropped(to: ciRect)
        let output: CIImage
        switch mode {
        case .mosaic:
            let filter = CIFilter.pixellate()
            filter.inputImage = cropped
            filter.scale = 20
            filter.center = CGPoint(x: ciRect.midX, y: ciRect.midY)
            output = filter.outputImage ?? cropped
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = cropped
            filter.radius = 24
            output = filter.outputImage ?? cropped
        default:
            return nil
        }
        let context = CIContext()
        guard let image = context.createCGImage(output, from: ciRect) else { return nil }
        return NSImage(cgImage: image, size: rect.size)
    }
}
