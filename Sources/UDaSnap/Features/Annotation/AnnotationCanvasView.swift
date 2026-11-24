import AppKit
import UDaSnapCore

@MainActor
final class InlineAnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCommit?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.option) || flags.contains(.shift) {
                insertNewline(nil)
                return
            }
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }
}

/// 标注画布。内部坐标一律使用原图像素、左上角原点；视图层再按 `zoom` 缩放。
@MainActor
final class AnnotationCanvasView: NSView, NSTextViewDelegate {

    enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum DragMode {
        case none
        case draft
        case move(index: Int, start: CGPoint, original: AnnotationObject)
        case resize(index: Int, handle: ResizeHandle, original: AnnotationObject)
        case crop(start: CGPoint)
    }

    var document: AnnotationDocument {
        didSet { needsDisplay = true }
    }
    var tool: AnnotationTool = .arrow {
        didSet { needsDisplay = true }
    }
    var style: AnnotationStyle = AnnotationStyle() {
        didSet { needsDisplay = true }
    }
    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            updateFrameSize()
            needsDisplay = true
        }
    }

    var onDocumentChange: (() -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onCropChange: ((CGRect?) -> Void)?
    var onZoomRequest: ((CGFloat) -> Void)?
    var onCancel: (() -> Void)?
    var onCanvasSizeChange: (() -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var isTextEditing: Bool { textEditor != nil }
    var currentCropRect: CGRect? { cropRect }

    private var selectedID: UUID?
    private var draft: AnnotationObject?
    private var draftStart: CGPoint = .zero
    private var dragMode: DragMode = .none
    private var cropRect: CGRect?
    private var textEditor: InlineAnnotationTextView?
    private var editingTextID: UUID?
    private var pendingTextOrigin: CGPoint?
    private var pendingTextStyle: AnnotationStyle?
    private var isEndingTextEditing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.canvasSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateFrameSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateFrameSize() {
        let size = CGSize(
            width: document.canvasSize.width * zoom,
            height: document.canvasSize.height * zoom)
        if frame.size != size {
            setFrameSize(size)
            onCanvasSizeChange?()
        }
    }

    func refreshCanvasSize() {
        updateFrameSize()
        needsDisplay = true
        onCanvasSizeChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: zoom, y: zoom)
        AnnotationPainter.draw(
            document: document,
            zoom: zoom,
            selectionID: selectedID,
            draft: draft,
            editingTextID: editingTextID,
            cropRect: cropRect,
            cropActive: tool == .crop && cropRect != nil
        )
        context.restoreGState()
    }

    // MARK: - Public actions

    func setTool(_ newTool: AnnotationTool) {
        guard newTool != tool else { return }
        commitTextEditing()
        if newTool != .crop {
            cropRect = nil
            onCropChange?(nil)
        }
        if newTool != .select {
            selectedID = nil
            onSelectionChange?(nil)
        }
        tool = newTool
        needsDisplay = true
    }

    func setSelected(_ id: UUID?) {
        selectedID = id
        onSelectionChange?(id)
        needsDisplay = true
    }

    func applyCrop() {
        guard let cropRect else { return }
        commitTextEditing()
        if document.crop(to: cropRect) {
            self.cropRect = nil
            selectedID = nil
            tool = .select
            onCropChange?(nil)
            refreshCanvasSize()
            onDocumentChange?()
        }
    }

    func cancelCrop() {
        cropRect = nil
        onCropChange?(nil)
        needsDisplay = true
    }

    func rotate(clockwise: Bool) {
        commitTextEditing()
        guard document.rotate(clockwise: clockwise) else { return }
        selectedID = nil
        cropRect = nil
        onCropChange?(nil)
        refreshCanvasSize()
        onDocumentChange?()
    }

    func flipHorizontally() {
        commitTextEditing()
        guard document.flipHorizontally() else { return }
        selectedID = nil
        cropRect = nil
        onCropChange?(nil)
        refreshCanvasSize()
        onDocumentChange?()
    }

    func undo() {
        commitTextEditing()
        guard document.canUndo else { return }
        document.undo()
        selectedID = nil
        cropRect = nil
        refreshCanvasSize()
        onDocumentChange?()
    }

    func redo() {
        commitTextEditing()
        guard document.canRedo else { return }
        document.redo()
        selectedID = nil
        cropRect = nil
        refreshCanvasSize()
        onDocumentChange?()
    }

    func deleteSelection() {
        guard let selectedID, let index = document.objects.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        document.checkpoint()
        document.remove(at: index)
        self.selectedID = nil
        onSelectionChange?(nil)
        onDocumentChange?()
        needsDisplay = true
    }

    func updateStyleForSelection(_ style: AnnotationStyle) {
        guard let selectedID, let index = document.objects.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        var object = document.objects[index]
        guard object.style != style else { return }
        document.checkpoint()
        object.style = style
        document.replace(object)
        onDocumentChange?()
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textEditor != nil {
            commitTextEditing()
        }
        let point = documentPoint(for: event)

        if tool == .crop {
            dragMode = .crop(start: point)
            cropRect = CGRect(origin: point, size: .zero)
            onCropChange?(cropRect)
            needsDisplay = true
            return
        }

        if tool == .select {
            if event.clickCount == 2, let index = document.hitTest(point, tolerance: 4 / zoom) {
                if case .text = document.objects[index].kind {
                    beginEditingExistingText(at: index)
                    return
                }
            }
            if let selectedID, let index = document.objects.firstIndex(where: { $0.id == selectedID }),
                let handle = handle(at: point, for: document.objects[index])
            {
                document.checkpoint()
                dragMode = .resize(index: index, handle: handle, original: document.objects[index])
                return
            }
            if let index = document.hitTest(point, tolerance: 4 / zoom) {
                let object = document.objects[index]
                selectedID = object.id
                onSelectionChange?(object.id)
                document.checkpoint()
                dragMode = .move(index: index, start: point, original: object)
                needsDisplay = true
                return
            }
            selectedID = nil
            onSelectionChange?(nil)
            needsDisplay = true
            return
        }

        if tool == .text {
            beginNewText(at: point)
            return
        }
        if tool == .number {
            addNumber(at: point)
            return
        }
        beginDraft(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = documentPoint(for: event)
        switch dragMode {
        case .none:
            break

        case .crop(let start):
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y))
            cropRect = rect.intersection(CGRect(origin: .zero, size: document.canvasSize))
            onCropChange?(cropRect)
            needsDisplay = true

        case .move(_, let start, let original):
            let delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            document.replace(original.translated(by: delta))
            needsDisplay = true

        case .resize(_, let handle, let original):
            let frame = resizedFrame(original.frame, handle: handle, to: point)
            document.replace(original.resized(from: original.frame, to: frame))
            needsDisplay = true

        case .draft:
            updateDraft(to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .crop:
            if let cropRect, cropRect.width < 4 || cropRect.height < 4 {
                self.cropRect = nil
                onCropChange?(nil)
            } else {
                onCropChange?(cropRect)
            }
            dragMode = .none
            needsDisplay = true

        case .move, .resize:
            dragMode = .none
            onDocumentChange?()

        case .draft:
            finishDraft()
            dragMode = .none

        case .none:
            break
        }
    }

    private func documentPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / max(zoom, 0.01), y: point.y / max(zoom, 0.01))
    }

    // MARK: - Draft drawing

    private func beginDraft(at point: CGPoint) {
        let style = self.style
        let kind: AnnotationKind
        switch tool {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .arrow: kind = .arrow(start: point, end: point)
        case .line: kind = .line(start: point, end: point)
        case .pen: kind = .pen([point])
        case .highlighter: kind = .highlighter([point])
        case .mosaic: kind = .mosaic
        case .blur: kind = .blur
        case .solid: kind = .solid
        default: return
        }
        draft = AnnotationObject(frame: CGRect(origin: point, size: .zero), kind: kind, style: style)
        draftStart = point
        dragMode = .draft
        needsDisplay = true
    }

    private func updateDraft(to point: CGPoint) {
        guard var draft else { return }
        switch draft.kind {
        case .rectangle, .ellipse, .mosaic, .blur, .solid:
            draft.frame = CGRect(
                x: min(draftStart.x, point.x),
                y: min(draftStart.y, point.y),
                width: abs(point.x - draftStart.x),
                height: abs(point.y - draftStart.y))
        case .arrow(let start, _):
            draft.kind = .arrow(start: start, end: point)
            draft.frame = boundingRect([start, point])
        case .line(let start, _):
            draft.kind = .line(start: start, end: point)
            draft.frame = boundingRect([start, point])
        case .pen(var points):
            points.append(point)
            draft.kind = .pen(points)
            draft.frame = boundingRect(points)
        case .highlighter(var points):
            points.append(point)
            draft.kind = .highlighter(points)
            draft.frame = boundingRect(points)
        case .text, .number:
            break
        }
        self.draft = draft
        needsDisplay = true
    }

    private func finishDraft() {
        guard let draft else { return }
        defer {
            self.draft = nil
            needsDisplay = true
        }
        let valid: Bool
        switch draft.kind {
        case .rectangle, .ellipse, .mosaic, .blur, .solid:
            valid = draft.frame.width >= 4 && draft.frame.height >= 4
        case .arrow(let start, let end), .line(let start, let end):
            valid = hypot(end.x - start.x, end.y - start.y) >= 4
        case .pen(let points), .highlighter(let points):
            valid = points.count >= 2 || draft.frame.width > 1 || draft.frame.height > 1
        case .text, .number:
            valid = false
        }
        guard valid else { return }
        document.checkpoint()
        document.add(draft)
        selectedID = draft.id
        onSelectionChange?(draft.id)
        onDocumentChange?()
    }

    private func boundingRect(_ points: [CGPoint]) -> CGRect {
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

    private func addNumber(at point: CGPoint) {
        document.checkpoint()
        let diameter = 28 * document.contentScale
        let frame = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter)
        let object = AnnotationObject(
            frame: frame,
            kind: .number(document.nextNumber),
            style: style)
        document.add(object)
        selectedID = object.id
        onSelectionChange?(object.id)
        onDocumentChange?()
        needsDisplay = true
    }

    // MARK: - Text

    private func beginNewText(at point: CGPoint) {
        pendingTextOrigin = point
        pendingTextStyle = style
        editingTextID = nil
        showTextEditor(text: "", origin: point, style: style)
    }

    private func beginEditingExistingText(at index: Int) {
        guard document.objects.indices.contains(index) else { return }
        let object = document.objects[index]
        guard case .text(let text) = object.kind else { return }
        document.checkpoint()
        selectedID = object.id
        onSelectionChange?(object.id)
        editingTextID = object.id
        pendingTextOrigin = object.frame.origin
        pendingTextStyle = object.style
        showTextEditor(text: text, origin: object.frame.origin, style: object.style)
        needsDisplay = true
    }

    private func showTextEditor(text: String, origin: CGPoint, style: AnnotationStyle) {
        textEditor?.removeFromSuperview()
        let scale = document.contentScale * zoom
        let font = AnnotationTextMetrics.font(size: style.fontSize * scale)
        let width = max(160, min(document.canvasSize.width * zoom - origin.x * zoom, 420 * scale))
        let height = max(font.pointSize * 2.4, 32)
        let frame = NSRect(
            x: origin.x * zoom - 2,
            y: origin.y * zoom - 2,
            width: width,
            height: height)

        let textView = InlineAnnotationTextView(frame: frame)
        textView.font = font
        textView.textColor = style.color.nsColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 3, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.commitTextEditing() }
        textView.string = text
        textView.wantsLayer = true
        textView.layer?.borderWidth = 1
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.cornerRadius = 3
        addSubview(textView)
        textEditor = textView
        window?.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, self.textEditor === textView else { return }
            self.window?.makeFirstResponder(textView)
        }
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isEndingTextEditing else { return }
        commitTextEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
                    || event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            {
                return false
            }
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    func commitTextEditing() {
        guard let textView = textEditor, !isEndingTextEditing else { return }
        isEndingTextEditing = true
        defer { isEndingTextEditing = false }

        let text = textView.string
        let style = pendingTextStyle ?? self.style
        let origin = pendingTextOrigin ?? CGPoint(x: 0, y: 0)
        let editingID = editingTextID
        textEditor = nil
        editingTextID = nil
        textView.onCommit = nil
        textView.removeFromSuperview()

        if text.isEmpty {
            if let editingID {
                document.remove(id: editingID)
                selectedID = nil
                onSelectionChange?(nil)
                onDocumentChange?()
            }
            pendingTextOrigin = nil
            pendingTextStyle = nil
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        }

        let size = AnnotationTextMetrics.size(
            for: text,
            style: style,
            contentScale: document.contentScale)
        let frame = CGRect(origin: origin, size: size)
        if let editingID, let index = document.objects.firstIndex(where: { $0.id == editingID }) {
            var object = document.objects[index]
            object.frame = frame
            object.kind = .text(text)
            object.style = style
            document.replace(object)
            selectedID = editingID
            onSelectionChange?(editingID)
        } else {
            document.checkpoint()
            let object = AnnotationObject(frame: frame, kind: .text(text), style: style)
            document.add(object)
            selectedID = object.id
            onSelectionChange?(object.id)
        }
        pendingTextOrigin = nil
        pendingTextStyle = nil
        textView.string = ""
        window?.makeFirstResponder(self)
        onDocumentChange?()
        needsDisplay = true
    }

    // MARK: - Selection geometry

    private func handle(at point: CGPoint, for object: AnnotationObject) -> ResizeHandle? {
        let frame = object.frame.standardized
        let tolerance = 7 / max(zoom, 0.01)
        let candidates: [(ResizeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.top, CGPoint(x: frame.midX, y: frame.minY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.right, CGPoint(x: frame.maxX, y: frame.midY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY)),
            (.bottom, CGPoint(x: frame.midX, y: frame.maxY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.left, CGPoint(x: frame.minX, y: frame.midY)),
        ]
        return candidates.first {
            abs(point.x - $0.1.x) <= tolerance && abs(point.y - $0.1.y) <= tolerance
        }?.0
    }

    private func resizedFrame(_ frame: CGRect, handle: ResizeHandle, to point: CGPoint) -> CGRect {
        let original = frame.standardized
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle {
        case .topLeft:
            minX = point.x
            minY = point.y
        case .top: minY = point.y
        case .topRight:
            maxX = point.x
            minY = point.y
        case .right: maxX = point.x
        case .bottomRight:
            maxX = point.x
            maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft:
            minX = point.x
            maxY = point.y
        case .left: minX = point.x
        }
        let minimum: CGFloat = 6
        if maxX - minX < minimum {
            if handle == .topLeft || handle == .bottomLeft || handle == .left {
                minX = maxX - minimum
            } else {
                maxX = minX + minimum
            }
        }
        if maxY - minY < minimum {
            if handle == .topLeft || handle == .topRight || handle == .top {
                minY = maxY - minimum
            } else {
                maxY = minY + minimum
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return }
        switch event.keyCode {
        case 53:  // Esc
            if tool == .crop, cropRect != nil {
                cancelCrop()
            } else if selectedID != nil {
                selectedID = nil
                onSelectionChange?(nil)
                needsDisplay = true
            } else {
                onCancel?()
            }
            return
        case 51, 117:  // Delete / Forward delete
            deleteSelection()
            return
        default:
            break
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        let shortcut: AnnotationTool?
        switch characters {
        case "v": shortcut = .select
        case "r": shortcut = .rectangle
        case "o": shortcut = .ellipse
        case "a": shortcut = .arrow
        case "l": shortcut = .line
        case "t": shortcut = .text
        case "n": shortcut = .number
        case "p": shortcut = .pen
        case "h": shortcut = .highlighter
        case "m": shortcut = .mosaic
        case "b": shortcut = .blur
        case "s": shortcut = .solid
        case "c": shortcut = .crop
        default: shortcut = nil
        }
        if let shortcut {
            onToolChange?(shortcut)
            setTool(shortcut)
        } else {
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        let proposed = zoom * (1 + event.magnification)
        onZoomRequest?(proposed)
    }
}
