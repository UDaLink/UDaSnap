import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// 标注颜色只在 Core 内保存 RGBA，渲染层再转换成 AppKit 颜色。
package struct AnnotationColor: Codable, Equatable, Sendable {
    package var red: CGFloat
    package var green: CGFloat
    package var blue: CGFloat
    package var alpha: CGFloat

    package init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    package static let annotationRed = AnnotationColor(red: 1, green: 0.23, blue: 0.19)
    package static let palette: [AnnotationColor] = [
        .annotationRed,
        AnnotationColor(red: 1, green: 0.58, blue: 0.0),
        AnnotationColor(red: 1, green: 0.80, blue: 0.0),
        AnnotationColor(red: 0.20, green: 0.78, blue: 0.35),
        AnnotationColor(red: 0.0, green: 0.48, blue: 1.0),
        AnnotationColor(red: 0.63, green: 0.35, blue: 0.92),
        AnnotationColor(red: 1, green: 1, blue: 1),
        AnnotationColor(red: 0.0, green: 0.0, blue: 0.0),
    ]
}

package struct AnnotationStyle: Equatable, Sendable {
    package var color: AnnotationColor
    /// 线宽、字号都以屏幕 point 计；导出时再乘截图的像素密度。
    package var lineWidth: CGFloat
    package var fontSize: CGFloat

    package init(color: AnnotationColor = .annotationRed, lineWidth: CGFloat = 3, fontSize: CGFloat = 18) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    package static let lineWidths: [CGFloat] = [2, 4, 7]
    package static let fontSizes: [CGFloat] = [14, 18, 24]
}

package enum AnnotationTool: String, CaseIterable, Sendable {
    case select
    case rectangle
    case ellipse
    case arrow
    case line
    case text
    case number
    case pen
    case highlighter
    case mosaic
    case blur
    case solid
    case crop

    package var isDrawingTool: Bool {
        switch self {
        case .select, .crop:
            return false
        case .rectangle, .ellipse, .arrow, .line, .text, .number, .pen, .highlighter, .mosaic, .blur, .solid:
            return true
        }
    }

    package var isRedactionTool: Bool {
        self == .mosaic || self == .blur || self == .solid
    }

    package var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .text: return "文字"
        case .number: return "序号"
        case .pen: return "画笔"
        case .highlighter: return "高亮"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .solid: return "色块"
        case .crop: return "裁剪"
        }
    }
}

package enum AnnotationKind: Equatable, Sendable {
    case rectangle
    case ellipse
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case text(String)
    case number(Int)
    case pen([CGPoint])
    case highlighter([CGPoint])
    case mosaic
    case blur
    case solid
}

package struct AnnotationObject: Identifiable, Equatable, Sendable {
    package let id: UUID
    package var frame: CGRect
    package var kind: AnnotationKind
    package var style: AnnotationStyle

    package init(
        id: UUID = UUID(),
        frame: CGRect,
        kind: AnnotationKind,
        style: AnnotationStyle
    ) {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.style = style
    }

    package var selectionBounds: CGRect {
        frame.standardized
    }

    package func hitTest(_ point: CGPoint, tolerance: CGFloat = 3) -> Bool {
        let bounds = frame.standardized.insetBy(dx: -tolerance, dy: -tolerance)
        return bounds.contains(point)
    }

    package func translated(by delta: CGVector) -> AnnotationObject {
        var copy = self
        copy.frame = frame.offsetBy(dx: delta.dx, dy: delta.dy)
        switch kind {
        case .arrow(let start, let end):
            copy.kind = .arrow(
                start: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy),
                end: CGPoint(x: end.x + delta.dx, y: end.y + delta.dy))
        case .line(let start, let end):
            copy.kind = .line(
                start: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy),
                end: CGPoint(x: end.x + delta.dx, y: end.y + delta.dy))
        case .pen(let points):
            copy.kind = .pen(points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
        case .highlighter(let points):
            copy.kind = .highlighter(points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
        default:
            break
        }
        return copy
    }

    /// 拖动选择框的边或角时，按原 frame 到新 frame 的比例缩放内容。
    package func resized(from oldFrame: CGRect, to newFrame: CGRect) -> AnnotationObject {
        let old = oldFrame.standardized
        let new = newFrame.standardized
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1

        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: new.minX + (point.x - old.minX) * sx,
                y: new.minY + (point.y - old.minY) * sy)
        }

        var copy = self
        copy.frame = new
        switch kind {
        case .arrow(let start, let end):
            copy.kind = .arrow(start: map(start), end: map(end))
        case .line(let start, let end):
            copy.kind = .line(start: map(start), end: map(end))
        case .pen(let points):
            copy.kind = .pen(points.map(map))
        case .highlighter(let points):
            copy.kind = .highlighter(points.map(map))
        case .text:
            copy.style.fontSize = max(6, style.fontSize * min(sx, sy))
        case .number:
            break
        default:
            break
        }
        return copy
    }
}

/// 标注文档。所有坐标都以原图像素、左上角为原点；`contentScale` 是像素 / point。
package struct AnnotationDocument {
    package private(set) var image: CGImage
    package var contentScale: CGFloat
    package var objects: [AnnotationObject]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let maxHistory = 80

    private struct Snapshot {
        let image: CGImage
        let objects: [AnnotationObject]
    }

    package init(image: CGImage, contentScale: CGFloat, objects: [AnnotationObject] = []) {
        self.image = image
        self.contentScale = max(1, contentScale)
        self.objects = objects
    }

    package var canvasSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }

    package var canUndo: Bool { !undoStack.isEmpty }
    package var canRedo: Bool { !redoStack.isEmpty }
    package var nextNumber: Int {
        (objects.compactMap {
            if case .number(let value) = $0.kind { return value }
            return nil
        }.max() ?? 0) + 1
    }

    /// 一次用户操作前调用一次；拖动中的连续更新不要再调用。
    package mutating func checkpoint() {
        undoStack.append(Snapshot(image: image, objects: objects))
        if undoStack.count > maxHistory {
            undoStack.removeFirst(undoStack.count - maxHistory)
        }
        redoStack.removeAll()
    }

    package mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(image: image, objects: objects))
        image = snapshot.image
        objects = snapshot.objects
    }

    package mutating func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(image: image, objects: objects))
        image = snapshot.image
        objects = snapshot.objects
    }

    package mutating func add(_ object: AnnotationObject) {
        objects.append(object)
    }

    package mutating func replace(_ object: AnnotationObject) {
        guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[index] = object
    }

    package mutating func remove(id: UUID) {
        objects.removeAll { $0.id == id }
    }

    package mutating func remove(at index: Int) {
        guard objects.indices.contains(index) else { return }
        objects.remove(at: index)
    }

    package func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Int? {
        for index in objects.indices.reversed() where objects[index].hitTest(point, tolerance: tolerance) {
            return index
        }
        return nil
    }

    /// 裁剪底图并把所有标注坐标平移到新画布；画布外的标注保留，渲染时被裁掉。
    @discardableResult
    package mutating func crop(to rect: CGRect) -> Bool {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let cropRect = rect.standardized.intersection(bounds).integral
        guard cropRect.width >= 2, cropRect.height >= 2 else { return false }
        guard let cropped = AnnotationImageTransformer.crop(image, to: cropRect) else { return false }

        checkpoint()
        image = cropped
        let delta = CGVector(dx: -cropRect.minX, dy: -cropRect.minY)
        objects = objects.map { $0.translated(by: delta) }
        return true
    }

    @discardableResult
    package mutating func rotate(clockwise: Bool) -> Bool {
        guard let rotated = AnnotationImageTransformer.rotate(image, clockwise: clockwise) else { return false }
        checkpoint()
        let oldWidth = CGFloat(image.width)
        let oldHeight = CGFloat(image.height)
        image = rotated

        if clockwise {
            objects = objects.map { object in
                var copy = object
                switch object.kind {
                case .rectangle, .ellipse, .mosaic, .blur, .solid:
                    let rect = object.frame.standardized
                    copy.frame = CGRect(
                        x: oldHeight - rect.maxY,
                        y: rect.minX,
                        width: rect.height,
                        height: rect.width)
                case .text, .number:
                    let center = CGPoint(x: object.frame.midX, y: object.frame.midY)
                    let newCenter = CGPoint(x: oldHeight - center.y, y: center.x)
                    copy.frame.origin = CGPoint(
                        x: newCenter.x - object.frame.width / 2,
                        y: newCenter.y - object.frame.height / 2)
                case .arrow(let start, let end):
                    copy.frame = rotatedFrame(object.frame, oldHeight: oldHeight, clockwise: true)
                    copy.kind = .arrow(
                        start: CGPoint(x: oldHeight - start.y, y: start.x),
                        end: CGPoint(x: oldHeight - end.y, y: end.x))
                case .line(let start, let end):
                    copy.frame = rotatedFrame(object.frame, oldHeight: oldHeight, clockwise: true)
                    copy.kind = .line(
                        start: CGPoint(x: oldHeight - start.y, y: start.x),
                        end: CGPoint(x: oldHeight - end.y, y: end.x))
                case .pen(let points):
                    let mapped = points.map { CGPoint(x: oldHeight - $0.y, y: $0.x) }
                    copy.frame = boundingRect(for: mapped)
                    copy.kind = .pen(mapped)
                case .highlighter(let points):
                    let mapped = points.map { CGPoint(x: oldHeight - $0.y, y: $0.x) }
                    copy.frame = boundingRect(for: mapped)
                    copy.kind = .highlighter(mapped)
                }
                return copy
            }
        } else {
            objects = objects.map { object in
                var copy = object
                switch object.kind {
                case .rectangle, .ellipse, .mosaic, .blur, .solid:
                    let rect = object.frame.standardized
                    copy.frame = CGRect(
                        x: rect.minY,
                        y: oldWidth - rect.maxX,
                        width: rect.height,
                        height: rect.width)
                case .text, .number:
                    let center = CGPoint(x: object.frame.midX, y: object.frame.midY)
                    let newCenter = CGPoint(x: center.y, y: oldWidth - center.x)
                    copy.frame.origin = CGPoint(
                        x: newCenter.x - object.frame.width / 2,
                        y: newCenter.y - object.frame.height / 2)
                case .arrow(let start, let end):
                    copy.frame = rotatedFrame(object.frame, oldHeight: oldWidth, clockwise: false)
                    copy.kind = .arrow(
                        start: CGPoint(x: start.y, y: oldWidth - start.x),
                        end: CGPoint(x: end.y, y: oldWidth - end.x))
                case .line(let start, let end):
                    copy.frame = rotatedFrame(object.frame, oldHeight: oldWidth, clockwise: false)
                    copy.kind = .line(
                        start: CGPoint(x: start.y, y: oldWidth - start.x),
                        end: CGPoint(x: end.y, y: oldWidth - end.x))
                case .pen(let points):
                    let mapped = points.map { CGPoint(x: $0.y, y: oldWidth - $0.x) }
                    copy.frame = boundingRect(for: mapped)
                    copy.kind = .pen(mapped)
                case .highlighter(let points):
                    let mapped = points.map { CGPoint(x: $0.y, y: oldWidth - $0.x) }
                    copy.frame = boundingRect(for: mapped)
                    copy.kind = .highlighter(mapped)
                }
                return copy
            }
        }
        return true
    }

    @discardableResult
    package mutating func flipHorizontally() -> Bool {
        guard let flipped = AnnotationImageTransformer.flipHorizontally(image) else { return false }
        checkpoint()
        let width = CGFloat(image.width)
        image = flipped
        objects = objects.map { object in
            var copy = object
            let rect = object.frame.standardized
            copy.frame = CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
            switch object.kind {
            case .arrow(let start, let end):
                copy.kind = .arrow(
                    start: CGPoint(x: width - start.x, y: start.y),
                    end: CGPoint(x: width - end.x, y: end.y))
            case .line(let start, let end):
                copy.kind = .line(
                    start: CGPoint(x: width - start.x, y: start.y),
                    end: CGPoint(x: width - end.x, y: end.y))
            case .pen(let points):
                copy.kind = .pen(points.map { CGPoint(x: width - $0.x, y: $0.y) })
            case .highlighter(let points):
                copy.kind = .highlighter(points.map { CGPoint(x: width - $0.x, y: $0.y) })
            default:
                break
            }
            return copy
        }
        return true
    }

    private func rotatedFrame(_ frame: CGRect, oldHeight: CGFloat, clockwise: Bool) -> CGRect {
        let rect = frame.standardized
        if clockwise {
            return CGRect(x: oldHeight - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
        return CGRect(x: rect.minY, y: oldHeight - rect.maxX, width: rect.height, height: rect.width)
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

package enum AnnotationImageTransformer {
    private static func makeContext() -> CIContext {
        CIContext(options: [.useSoftwareRenderer: false])
    }

    package static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let height = CGFloat(image.height)
        let ciRect = CGRect(
            x: rect.minX,
            y: height - rect.maxY,
            width: rect.width,
            height: rect.height)
        return makeContext().createCGImage(ci.cropped(to: ciRect), from: ciRect)
    }

    package static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let oriented = ci.oriented(forExifOrientation: clockwise ? 6 : 8)
        return makeContext().createCGImage(oriented, from: oriented.extent)
    }

    package static func flipHorizontally(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let oriented = ci.oriented(forExifOrientation: 2)
        return makeContext().createCGImage(oriented, from: oriented.extent)
    }
}
