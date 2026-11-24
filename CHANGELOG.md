# 更新记录

## 1.0.0 — 2026-11-24

首个重新出发的版本，仓库从空目录按 `App / Core / Features / Shared` 分层重建。

### 新增

- 独立的 `UDaSnapCore` library target，承载配置、策略、AI 客户端、OCR、滚动拼接、命名与保留清理。
- `AppEnvironment` 组合根，统一创建 AI 配置、逐接口同意与合规存储。
- Swift 6 严格并发基线；AppKit 控制器统一主线程隔离。
- `.swift-format` 格式基线、XCTest Core 测试、GitHub Actions CI 与 Release 工作流。
- 新的产品定位 **“UDaSnap — 截图即用 / Capture. Understand. Use.”**。

### 迁移

- Bundle ID 更新为 `com.udalink.udasnap`，配置目录同步更新；不读取旧 `com.audan.UDaSnap` 配置。
- 版本重置为 `1.0.0` / build `1`。
- 默认 ad-hoc 签名；显式 `SIGN_IDENTITY` 时使用固定证书。
- 隐私政策版本 `1.0`，生效日 `2026-11-24`。

### 兼容

- 用户可见功能与 1.6.1 等价：贴图、框选保存、窗口截图、滚动长图、OCR、AI 双模式、逐段翻译、小U 对话、首次启动同意、隐私与数据页。
- 不迁移旧版本配置、旧截图目录或旧钥匙串条目。
