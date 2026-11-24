import AppKit
import UDaSnapCore

/// 标注窗口与现有截图存储之间的桥。
@MainActor
final class AnnotationCoordinator {

    private let pinStore: PinStore
    private var editors: [AnnotationEditorWindowController] = []
    private var nextCascadeIndex = 0
    var onSaved: ((Bool) -> Void)?

    init(pinStore: PinStore) {
        self.pinStore = pinStore
    }

    func present(
        image: CGImage,
        contentScale: CGFloat,
        screen: NSScreen,
        pinOrigin: CGPoint
    ) {
        if editors.isEmpty {
            nextCascadeIndex = 0
        }
        let document = AnnotationDocument(image: image, contentScale: contentScale)
        let cascadeIndex = nextCascadeIndex
        nextCascadeIndex += 1
        let editor = AnnotationEditorWindowController(
            document: document, screen: screen, cascadeIndex: cascadeIndex)
        editors.append(editor)
        editor.onFinish = { [weak self, weak editor] action in
            guard let self, let editor else { return }
            self.remove(editor)
            switch action {
            case .cancel:
                break
            case .done(let image):
                self.commit(image, pinOrigin: pinOrigin, screen: screen, makePin: false)
            case .pin(let image):
                self.commit(image, pinOrigin: pinOrigin, screen: screen, makePin: true)
            }
        }
        editor.show()
    }

    func dismiss() {
        let openEditors = editors
        editors.removeAll()
        for editor in openEditors {
            editor.onFinish = nil
            editor.close()
        }
    }

    private func remove(_ editor: AnnotationEditorWindowController) {
        editors.removeAll { $0 === editor }
    }

    private func commit(_ image: CGImage, pinOrigin: CGPoint, screen: NSScreen, makePin: Bool) {
        ScreenshotStorage.copyToClipboard(image)
        let saved = ScreenshotStorage.savePNG(image)
        if makePin {
            let pin = PinWindowController(image: image, origin: pinOrigin, onScreen: screen)
            pinStore.add(pin)
        }
        if saved != nil {
            HUDController.shared.show(
                title: makePin ? "已贴图" : "已保存",
                detail: makePin ? "已复制、保存并贴图" : "已复制并保存",
                at: NSEvent.mouseLocation,
                success: true
            )
            onSaved?(true)
        } else {
            HUDController.shared.show(
                title: "保存失败",
                detail: "已复制到剪贴板，检查 ~/Pictures/UDaSnap 写入权限",
                at: NSEvent.mouseLocation,
                success: false
            )
            onSaved?(false)
        }
    }
}
