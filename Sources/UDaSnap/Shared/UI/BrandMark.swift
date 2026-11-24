import AppKit
import UDaSnapCore

/// UDaSnap 的品牌标记：U 形取景框。
/// 应用图标与菜单栏共用这一条路径，保证两处是同一枚字形。
enum BrandMark {

    /// 在 18pt 坐标系里定义，绘制时按 rect 宽度等比缩放。
    static func drawSnapU(in rect: NSRect, color: NSColor) {
        let s = rect.width / 18
        let ox = rect.minX
        let oy = rect.minY

        let path = NSBezierPath()
        path.move(to: NSPoint(x: ox + 4.05 * s, y: oy + 15.2 * s))
        path.line(to: NSPoint(x: ox + 4.05 * s, y: oy + 7.25 * s))
        path.curve(
            to: NSPoint(x: ox + 9.0 * s, y: oy + 2.75 * s),
            controlPoint1: NSPoint(x: ox + 4.05 * s, y: oy + 4.75 * s),
            controlPoint2: NSPoint(x: ox + 6.15 * s, y: oy + 2.75 * s)
        )
        path.curve(
            to: NSPoint(x: ox + 13.95 * s, y: oy + 7.25 * s),
            controlPoint1: NSPoint(x: ox + 11.85 * s, y: oy + 2.75 * s),
            controlPoint2: NSPoint(x: ox + 13.95 * s, y: oy + 4.75 * s)
        )
        path.line(to: NSPoint(x: ox + 13.95 * s, y: oy + 15.2 * s))

        // 顶部两段短横：让 U 读成取景框，而不只是字母。
        path.move(to: NSPoint(x: ox + 4.05 * s, y: oy + 15.2 * s))
        path.line(to: NSPoint(x: ox + 6.55 * s, y: oy + 15.2 * s))
        path.move(to: NSPoint(x: ox + 13.95 * s, y: oy + 15.2 * s))
        path.line(to: NSPoint(x: ox + 11.45 * s, y: oy + 15.2 * s))

        path.lineWidth = 2.8 * s
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 菜单栏模板图标，18pt。颜色由系统菜单栏决定，不要在这里固定白/黑。
    static func statusImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            drawSnapU(in: NSRect(x: 0, y: 0, width: side, height: side), color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
