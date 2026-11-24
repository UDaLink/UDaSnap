import CoreGraphics
import Vision

/// 一张参与拼接的滚动帧。`shift` 是相对上一帧的纵向位移（像素）。
package struct ScrollFrame: Sendable {
    package let image: CGImage
    package let shift: Int

    package init(image: CGImage, shift: Int) {
        self.image = image
        self.shift = shift
    }
}

/// 长图拼接：识别相邻帧的重叠位移，剔除固定在顶部/底部的工具栏，再逐段拼起来。
package enum ScrollStitcher {

    package static let maxHeight = 60000

    /// 通过横向采样后的灰度行指纹，寻找 current 顶部相对 previous 的纵向位移。
    /// 只在画面中部取样，避免固定表头/底栏干扰。
    package static func shift(from previous: CGImage, to current: CGImage) -> Int? {
        // Vision 的平移配准对文字、图片、纯色背景都更稳；先裁掉固定表头/底栏再配准。
        if let visionShift = visionShift(from: previous, to: current) {
            return visionShift
        }

        // Safari 等浏览器的顶部工具栏会在滚动时收起/展开。首帧和当前帧的固定区域高度
        // 不一致时，整帧配准会失败；再裁掉顶部 25% 用纯正文重试一次。
        if let fallback = visionShiftCroppedTop(
            from: previous, to: current,
            topInset: Int(Double(previous.height) * 0.25))
        {
            return fallback
        }

        guard let p = RowProfile(image: previous),
            let c = RowProfile(image: current),
            p.height == c.height,
            p.width == c.width,
            p.height > 32
        else { return nil }

        let h = p.height
        let probeRows = min(32, max(6, h / 18))
        let probes = [0.25, 0.45, 0.65, 0.85].map {
            min(h - probeRows - 1, max(0, Int(Double(h) * $0)))
        }
        let maxShift = h - probeRows - 1
        guard maxShift > 8 else { return nil }

        var bestShift = 0
        var bestScore = Int.max
        var bestCount = 0

        for d in 1...maxShift {
            var score = 0
            var count = 0
            for probe in probes {
                let currentY = min(probe, h - probeRows - 1)
                let previousY = currentY + d
                guard previousY >= 0, previousY + probeRows <= h else { continue }
                for row in 0..<probeRows {
                    score += p.rowDifference(y: previousY + row, other: c, otherY: currentY + row)
                    count += p.sampleCount
                }
            }
            guard count > 0 else { continue }
            let average = score / count
            if average < bestScore {
                bestScore = average
                bestShift = d
                bestCount = count
            }
        }

        // 完全相同的画面不代表有滚动；平均差异太大则说明没有找到可信重叠。
        guard bestShift > 0, bestCount > 0, bestScore <= 12 else { return nil }
        return bestShift
    }

    /// 拼合所有帧，按 maxHeight 截断。header/footer 只在输出里保留一次。
    package static func compose(frames: [ScrollFrame], maxHeight: Int = ScrollStitcher.maxHeight) -> CGImage? {
        guard let first = frames.first else { return nil }
        guard maxHeight > 0 else { return nil }
        if frames.count == 1 { return first.image }

        let width = first.image.width
        let height = first.image.height
        guard width > 0, height > 0 else { return nil }

        guard let firstProfile = RowProfile(image: first.image),
            let secondProfile = RowProfile(image: frames[1].image),
            firstProfile.height == height,
            secondProfile.height == height
        else {
            return simpleCompose(frames: frames, maxHeight: maxHeight)
        }

        let bands = staticBands(first: firstProfile, second: secondProfile)
        var header = bands.top
        var footer = bands.bottom
        if header + footer >= height - 8 {
            header = 0
            footer = 0
        }

        // 只剔除真正贯穿所有帧的固定侧栏。不能只看前两帧：聊天/网页右侧的空白边距
        // 在开头可能为空，后面才出现右对齐气泡；只看前两帧会把这段空白误判成固定侧栏，
        // 把后面帧的正文右边整条裁掉（用户那张 2400×22181 长图右侧透明 279px 就是这个原因）。
        var leftInset = 0
        var rightInset = 0
        if let c1 = ColumnProfile(image: first.image) {
            let columns = staticColumns(first: c1, frames: frames)
            leftInset = columns.left
            rightInset = columns.right
            if leftInset + rightInset >= width - 8 {
                leftInset = 0
                rightInset = 0
            }
        }
        let bodyX = leftInset
        let bodyWidth = max(1, width - leftInset - rightInset)

        let bodyStart = header
        let bodyEnd = height - footer
        let initialBodyHeight = bodyEnd - bodyStart
        guard initialBodyHeight > 0 else { return simpleCompose(frames: frames, maxHeight: maxHeight) }

        // 先估算总高，避免在绘制中途才发现超出上限。
        // 每一帧的新内容就是相对上一帧的位移量，不能拿“当前页高”去首帧的 bodyEnd 里找。
        var predictedBody = initialBodyHeight
        for frame in frames.dropFirst() where frame.shift > 0 {
            predictedBody += frame.shift
            if header + predictedBody + footer >= maxHeight { break }
        }

        let canvasHeight = min(maxHeight, header + predictedBody + footer)
        guard canvasHeight > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .none

        if header > 0 {
            draw(
                first.image, sourceY: 0, height: header, destY: 0,
                context: context, canvasHeight: canvasHeight)
        }

        var bodyHeight = initialBodyHeight
        draw(
            first.image, sourceY: bodyStart, height: initialBodyHeight,
            destY: header, context: context, canvasHeight: canvasHeight)

        for frame in frames.dropFirst() where frame.shift > 0 {
            // 当前帧画面与上一帧重叠；新露出的内容位于当前帧 body 的末尾 shift 像素。
            let sourceY = max(bodyStart, bodyEnd - frame.shift)
            let destY = header + bodyHeight
            let limit = max(0, canvasHeight - footer - destY)
            guard limit > 0 else { break }
            let drawHeight = min(bodyEnd - sourceY, limit)
            guard drawHeight > 0 else { break }
            draw(
                frame.image, sourceY: sourceY, sourceX: bodyX, width: bodyWidth, height: drawHeight,
                destX: bodyX, destY: destY, context: context, canvasHeight: canvasHeight)
            bodyHeight += drawHeight
            if drawHeight < bodyEnd - sourceY { break }
        }

        if footer > 0 {
            let destY = header + bodyHeight
            let drawHeight = min(footer, max(0, canvasHeight - destY))
            if drawHeight > 0 {
                draw(
                    frames.last!.image, sourceY: height - footer, height: drawHeight,
                    destY: destY, context: context, canvasHeight: canvasHeight)
            }
        }

        return context.makeImage()
    }

    // MARK: - 内部实现

    /// 用 Vision 估计上一帧到当前帧的纵向位移。只接受“内容向上移动”的正向结果。
    private static func visionShift(from previous: CGImage, to current: CGImage) -> Int? {
        let width = previous.width
        let height = previous.height
        guard width == current.width, height == current.height, height > 64 else { return nil }

        // 用第一帧/当前帧的行指纹判断固定表头/底栏，裁掉后再配准，避免固定区域把位移拉回 0。
        var header = 0
        var footer = 0
        if let p = RowProfile(image: previous), let c = RowProfile(image: current) {
            let bands = staticBands(first: p, second: c)
            header = bands.top
            footer = bands.bottom
            if header + footer >= height - 8 {
                header = 0
                footer = 0
            }
        }
        let bodyHeight = height - header - footer
        guard bodyHeight > 32 else { return nil }
        guard let previousBody = previous.cropping(to: CGRect(x: 0, y: header, width: width, height: bodyHeight)),
            let currentBody = current.cropping(to: CGRect(x: 0, y: header, width: width, height: bodyHeight))
        else {
            return nil
        }

        // Vision 不需要原始分辨率；缩到 640 宽可以显著降低 4K 长图每帧配准的耗时。
        let visionWidth = min(640, width)
        let scale = Double(visionWidth) / Double(width)
        let visionHeight = max(32, Int(Double(bodyHeight) * scale))
        guard let previousSmall = resized(previousBody, width: visionWidth, height: visionHeight),
            let currentSmall = resized(currentBody, width: visionWidth, height: visionHeight)
        else {
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currentSmall, options: [:])
        let handler = VNImageRequestHandler(cgImage: previousSmall, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        let ty = observation.alignmentTransform.ty
        // 向下滚动时，当前帧内容整体向上移动，Vision 给出负 ty。
        guard ty < -4 else { return nil }
        let shift = Int(((-ty) / scale).rounded())
        // 底部只剩固定底栏/空白时，配准可能给出异常大的位移；限制在视口的 60% 以内。
        guard shift > 4, shift < min(bodyHeight - 4, Int(Double(bodyHeight) * 0.6)) else { return nil }
        return shift
    }

    /// 从两帧相同高度的顶部裁掉一段后做平移配准，专门兜住动态收起的浏览器工具栏。
    private static func visionShiftCroppedTop(from previous: CGImage, to current: CGImage, topInset: Int) -> Int? {
        let width = previous.width
        let height = previous.height
        guard width == current.width, height == current.height, height > 64 else { return nil }
        let inset = max(0, min(height - 32, topInset))
        let bodyHeight = height - inset
        guard bodyHeight > 32,
            let previousBody = previous.cropping(to: CGRect(x: 0, y: inset, width: width, height: bodyHeight)),
            let currentBody = current.cropping(to: CGRect(x: 0, y: inset, width: width, height: bodyHeight))
        else {
            return nil
        }
        let visionWidth = min(640, width)
        let scale = Double(visionWidth) / Double(width)
        let visionHeight = max(32, Int(Double(bodyHeight) * scale))
        guard let previousSmall = resized(previousBody, width: visionWidth, height: visionHeight),
            let currentSmall = resized(currentBody, width: visionWidth, height: visionHeight)
        else {
            return nil
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currentSmall, options: [:])
        let handler = VNImageRequestHandler(cgImage: previousSmall, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let shift = Int(((-observation.alignmentTransform.ty) / scale).rounded())
        guard shift > 4, shift < Int(Double(bodyHeight) * 0.75) else { return nil }
        return shift
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func simpleCompose(frames: [ScrollFrame], maxHeight: Int) -> CGImage? {
        guard let first = frames.first else { return nil }
        let width = first.image.width
        let height = first.image.height
        let canvasHeight = min(maxHeight, height)
        guard canvasHeight > 0,
            let context = CGContext(
                data: nil, width: width, height: canvasHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .none
        draw(
            first.image, sourceY: 0, height: min(height, canvasHeight), destY: 0,
            context: context, canvasHeight: canvasHeight)
        return context.makeImage()
    }

    private static func draw(
        _ image: CGImage,
        sourceY: Int,
        sourceX: Int = 0,
        width: Int? = nil,
        height: Int,
        destX: Int = 0,
        destY: Int,
        context: CGContext,
        canvasHeight: Int
    ) {
        let drawWidth = width ?? image.width
        guard height > 0, drawWidth > 0, sourceX >= 0, sourceX + drawWidth <= image.width,
            let crop = image.cropping(
                to: CGRect(
                    x: sourceX, y: sourceY,
                    width: drawWidth, height: height))
        else { return }
        // sourceY/destY 都是以左上角为原点的页坐标；CGContext 的绘制原点在左下角。
        let rect = CGRect(
            x: destX,
            y: canvasHeight - destY - height,
            width: drawWidth,
            height: height)
        context.draw(crop, in: rect)
    }

    /// 找出真正贯穿所有帧的固定左侧栏/右侧栏。
    /// 必须用全部帧做判断：聊天窗口右侧开头两帧可能是空白，后面才出现右对齐气泡；
    /// 若只看首帧和第二帧，会把这段空白误判成固定侧栏，裁掉后面帧的右侧正文。
    private static func staticColumns(first: ColumnProfile, frames: [ScrollFrame]) -> (left: Int, right: Int) {
        let w = first.width
        let maxBand = max(12, min(280, w / 4))
        let others: [ColumnProfile] = frames.dropFirst().compactMap { ColumnProfile(image: $0.image) }
        guard !others.isEmpty else { return (0, 0) }

        var left = 0
        while left < maxBand {
            if others.contains(where: { first.columnDifference(x: left, other: $0, otherX: left) > 4 }) { break }
            left += 1
        }
        var right = 0
        while right < maxBand {
            let x = w - 1 - right
            if others.contains(where: { first.columnDifference(x: x, other: $0, otherX: x) > 4 }) { break }
            right += 1
        }
        // 只有边带里真的存在可见内容（文字/图标/边界块）才当作固定侧栏。
        // 聊天窗口和网页两侧常见的纯白边距也会“每帧都不变”，只看列指纹会把它们
        // 当成固定侧栏裁掉，长图两边就会留下透明竖条。空白边距必须保留。
        if left > 0, !first.hasVisibleContent(from: 0, to: left) { left = 0 }
        if right > 0, !first.hasVisibleContent(from: w - right, to: w) { right = 0 }
        if left + right >= w - 8 { return (0, 0) }
        return (left, right)
    }

    /// 找出首帧和第二帧中位置不变、内容相同的顶部/底部区域。
    private static func staticBands(first: RowProfile, second: RowProfile) -> (top: Int, bottom: Int) {
        let h = first.height
        let maxBand = max(12, min(220, h / 4))
        var top = 0
        while top < maxBand {
            if first.rowDifference(y: top, other: second, otherY: top) > 4 { break }
            top += 1
        }
        var bottom = 0
        while bottom < maxBand {
            let y = h - 1 - bottom
            if first.rowDifference(y: y, other: second, otherY: y) > 4 { break }
            bottom += 1
        }
        return (top, bottom)
    }
}

/// 把图像纵向压缩成少量灰度采样，生成每列的指纹。用于识别固定左右侧栏。
private struct ColumnProfile {
    let width: Int
    let height: Int
    let sampleCount: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        let w = image.width
        let samples = min(32, max(8, image.height / 8))
        guard w > 0, samples > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * samples)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base,
                    width: w,
                    height: samples,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: samples))
            return true
        }
        guard ok else { return nil }
        self.width = w
        self.height = samples
        self.sampleCount = samples
        self.pixels = data
    }

    func columnDifference(x: Int, other: ColumnProfile, otherX: Int) -> Int {
        guard x >= 0, x < width, otherX >= 0, otherX < other.width, height == other.height else { return 255 }
        var sum = 0
        for y in 0..<height {
            sum += abs(Int(pixels[y * width + x]) - Int(other.pixels[y * other.width + otherX]))
        }
        return sum / height
    }

    /// 边带内是否有足够的可见内容，避免把纯白/纯色空白边距当成固定侧栏。
    func hasVisibleContent(from start: Int, to end: Int) -> Bool {
        let lo = max(0, start)
        let hi = min(width, end)
        guard lo < hi else { return false }
        var visibleColumns = 0
        for x in lo..<hi {
            var minValue = 255
            var maxValue = 0
            for y in 0..<height {
                let v = Int(pixels[y * width + x])
                if v < minValue { minValue = v }
                if v > maxValue { maxValue = v }
            }
            if maxValue - minValue >= 12 {
                visibleColumns += 1
                if visibleColumns >= 3 { return true }
            }
        }
        return false
    }
}

/// 把图像横向压缩成少量灰度采样，生成每行的指纹。只用于匹配，不参与最终画质。
private struct RowProfile {
    let width: Int
    let height: Int
    let sampleCount: Int
    private let pixels: [UInt8]

    init?(image: CGImage) {
        let h = image.height
        let samples = min(32, max(8, image.width / 8))
        guard h > 0, samples > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: samples * h)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base,
                    width: samples,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: samples,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: samples, height: h))
            return true
        }
        guard ok else { return nil }

        self.width = samples
        self.height = h
        self.sampleCount = samples
        self.pixels = data
    }

    func rowDifference(y: Int, other: RowProfile, otherY: Int) -> Int {
        guard y >= 0, y < height, otherY >= 0, otherY < other.height,
            sampleCount == other.sampleCount
        else { return 255 }
        let a = y * sampleCount
        let b = otherY * sampleCount
        var sum = 0
        for x in 0..<sampleCount {
            sum += abs(Int(pixels[a + x]) - Int(other.pixels[b + x]))
        }
        return sum / sampleCount
    }
}
