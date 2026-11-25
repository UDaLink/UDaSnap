# 架构

## 目标

UDaSnap 1.2.0 延续“截图即用”的分层：Core 负责可测试的标注模型与图像变换，App 负责画布、工具栏和窗口表现；后续功能仍按 **Core 纯逻辑 / App 表现层** 扩展。

## 目录

```
Sources/
  UDaSnapCore/                 # 可测试的纯逻辑，不依赖 AppKit
    Configuration/             # AISettings、AppPaths、AIConfigStore
    Security/                  # endpoint 策略、同意键、钥匙串
    AI/                        # OpenAI 兼容客户端、翻译语言、图片编码
    Annotation/                # 标注模型、撤销历史、裁剪/旋转/翻转
    OCR/                       # Vision OCR
    Imaging/                   # 滚动拼接
    Storage/                   # 文件命名、保留清理
    Utilities/                 # OSLog
  UDaSnap/                     # AppKit 表现层与入口
    App/                       # main、AppDelegate、AppEnvironment
    Features/
      Capture/                 # 选区、窗口选择、截图、截图存储
      Annotation/              # 标注编辑器、画布、工具栏、渲染与输出
      Scroll/                  # 滚动采集与预览
      OCR/                     # OCR 结果窗
      AI/                      # AI 结果窗、AI 设置、逐接口同意
      Pin/                     # 贴图浮窗
      Shortcuts/               # 全局热键
      Settings/                # 偏好设置、合规与法律文档
      Onboarding/              # 首次启动与法律文档窗
    Shared/UI/                 # 品牌标记、HUD
Tests/
  UDaSnapCoreTests/            # 只覆盖 Core 纯逻辑
Resources/                     # AppIcon 等
scripts/                       # 发布辅助脚本
docs/                          # 使用、架构、开发文档
```

## 分层规则

### UDaSnapCore

- 只允许 `Foundation`、`CoreGraphics`、`ImageIO`、`CoreText`、`Vision`、`Security`、`URLSession` 等系统框架。
- **禁止 `import AppKit` 和 `import Carbon`**。任何窗口、面板、菜单、NSAlert、NSImage、剪贴板和应用生命周期代码都留在 App 层。
- 对外 API 使用 `package` 访问级别，只暴露 App 需要的最小表面。
- Core 不读 `UserDefaults.standard`、不读 `Bundle.main`、不直接决定 UI 文案；路径与策略由 Core 提供，App 负责展示。

### UDaSnap App

- 负责 AppKit 窗口、菜单栏、快捷键、剪贴板、权限弹窗和文件面板。
- `AppEnvironment` 是组合根：创建 `AIConfigStore`、`AIConsentCoordinator`、`ComplianceStore`，并作为长生命周期状态的唯一所有者。
- 控制器通过初始化参数接收依赖；少量 AppKit 回调使用组合根，不再各自持有 `static shared` store。
- 不保留旧 API 兼容层；类型、文件、成员统一命名，旧名不进入新仓库。

## 标注

- `UDaSnapCore/Annotation` 定义 `AnnotationDocument`：持有原图、对象数组、撤销/重做快照。
- 坐标统一为原图像素、左上角原点；`contentScale` 表示像素 / point，样式尺寸按 point 存储、渲染时乘 `contentScale`。
- 裁剪、左右 90° 旋转、水平翻转都会同步变换已有对象；文字与序号保持正向可读，只移动中心位置。
- `AnnotationRenderer` 在导出时把基础图、所有对象与隐私遮挡绘制成一张 CGImage；马赛克/模糊/色块在导出阶段烘焙为像素。
- App 层的 `AnnotationCanvasView` 负责选择、拖动、缩放、内联文字、裁剪选区与快捷键；`AnnotationEditorWindowController` 只管独立置顶窗口与工具栏布局。

## 立即截图

- `CaptureMode.immediate` 复用 `RegionSelectionController` 的全屏遮罩和截图缓存；拖拽结束后不立即 `teardown`。
- `SelectionView` 在完成态维护 `.newSelection / .move / .resize(Handle)` 三种拖拽状态；鼠标抬起后保留八个手柄，操作条按选区位置实时布局。
- `ImmediateSelectionBarView` 是独立于 `SelectionView` 的兄弟视图，避免被选区裁剪；浅色 `.popover` 毛玻璃 + 深色图标文字。
- 真正执行标注、贴图或保存时才裁剪并关闭遮罩；取消和 `Esc` 直接结束，不产生文件或剪贴板副作用。
- 标注复用 `AnnotationCoordinator`；贴图和保存复用现有贴图 / 缩略图路径。

## 并发

- Swift 6 tools + Swift 6 语言模式，启用严格并发检查。
- AppKit 类型和控制器统一 `@MainActor`。
- Core 的配置、策略、拼接、命名模型为 `Sendable`；跨 actor 传递的值类型必须可发送。
- 异步流程优先 `async/await` 与 `Task`；需要持续输出的 AI 对话使用 `AsyncThrowingStream` / SSE 回调桥接。旧 `DispatchQueue.asyncAfter` 逐步改为 `Task.sleep`。
- 不在 `deinit` 中访问 actor 隔离状态；观察者令牌用 `nonisolated(unsafe)` 保存，只用于移除通知。

## 数据与路径

| 数据 | 路径 |
|---|---|
| 截图 | `~/Pictures/UDaSnap/` |
| 快捷键 | `~/Library/Application Support/com.udalink.udasnap/settings.json` |
| AI 配置 | `~/Library/Application Support/com.udalink.udasnap/ai-settings.json` |
| 合规记录 | `~/Library/Application Support/com.udalink.udasnap/compliance.json` |
| API Key | macOS 钥匙串，service `com.udalink.udasnap.ai`，account `api-key` |
| AI 逐接口同意 | `UserDefaults` key `UDaSnap.aiConsent.v1` |

路径常量集中在 `UDaSnapCore/Configuration/AppPaths.swift`。不读取旧 `com.audan.UDaSnap` 目录，不迁移旧配置。

## 测试边界

- XCTest 只测 Core：endpoint 策略、同意键归一化、设置 Codable、翻译语言、截图命名与保留、滚动拼接，以及标注编号、撤销/重做、裁剪、旋转、翻转与命中测试。
- 不做 UI 自动化；App 层用本地 `swift build`、`--self-test` 和手动冒烟验证。
- CI 在 macOS 上跑 `swift test` 与 `swift format lint`；Release 工作流只在 tag 或手动触发时打包 Universal `.app`。

## 构建产物

`build.sh` 用 SwiftPM 构建 `arm64 + x86_64` release 可执行，手工组装 `.app`，写入 `Info.plist`，复制图标与法律文档，最后签名。默认 ad-hoc；传入 `SIGN_IDENTITY` 才使用固定证书。二进制不进入仓库。
