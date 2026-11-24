# 架构

## 目标

UDaSnap 1.0.0 是按“截图即用”重新组织的一版实现：产品行为与 1.6.1 保持一致，但代码从空目录重建，围绕 **Core 纯逻辑 / App 表现层** 分层，方便测试、替换和长期维护。

## 目录

```
Sources/
  UDaSnapCore/                 # 可测试的纯逻辑，不依赖 AppKit
    Configuration/             # AISettings、AppPaths、AIConfigStore
    Security/                  # endpoint 策略、同意键、钥匙串
    AI/                        # OpenAI 兼容客户端、翻译语言、图片编码
    OCR/                       # Vision OCR
    Imaging/                   # 滚动拼接
    Storage/                   # 文件命名、保留清理
    Utilities/                 # OSLog
  UDaSnap/                     # AppKit 表现层与入口
    App/                       # main、AppDelegate、AppEnvironment
    Features/
      Capture/                 # 选区、窗口选择、截图、截图存储
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

- XCTest 只测 Core：endpoint 策略、同意键归一化、设置 Codable、翻译语言、截图命名与保留、滚动拼接。
- 不做 UI 自动化；App 层用本地 `swift build`、`--self-test` 和手动冒烟验证。
- CI 在 macOS 上跑 `swift test` 与 `swift format lint`；Release 工作流只在 tag 或手动触发时打包 Universal `.app`。

## 构建产物

`build.sh` 用 SwiftPM 构建 `arm64 + x86_64` release 可执行，手工组装 `.app`，写入 `Info.plist`，复制图标与法律文档，最后签名。默认 ad-hoc；传入 `SIGN_IDENTITY` 才使用固定证书。二进制不进入仓库。
