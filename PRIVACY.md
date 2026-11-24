# UDaSnap 隐私政策

**版本：1.0**  
**生效日期：2026-11-24**  
**运营者：UDaSnap 项目维护者**  
**联系渠道：GitHub Issues；涉及敏感信息时请使用仓库 Security 的私密报告**

UDaSnap（以下简称“本应用”）是一个 macOS 菜单栏截图工具。本政策说明本应用处理哪些数据、为什么处理、保存在哪里、可能发送给谁，以及你可以如何管理这些数据。

本应用主要面向中国大陆用户，适用中华人民共和国法律。本政策不构成对欧盟 GDPR、美国 CCPA 或其他特定法域专项合规的承诺；如你所在地区有强制性法律规定，以该等法律规定为准。

## 1. 核心原则

- **本地优先**：截图、贴图、滚动拼接和文字提取默认只在这台 Mac 上完成。
- **AI 可选**：只有你主动使用 AI 识别、AI 翻译或“小U”对话时，相关数据才会发送到你填写的接口。
- **不卖数据、不做广告、不做遥测**：本应用不收集统计指标，不上报崩溃，不写入远程日志，不自动检查更新，也不出售或出租任何数据。
- **最小化保存**：API Key 只保存在本机 macOS 登录钥匙串的通用密码条目（service `com.udalink.udasnap.ai`，account `api-key`）；配置文件不包含 Key；AI 日常不主动读取 Key，只有当前构建已授权时才静默读取；AI 对话只存在于当前窗口内。

## 2. 本应用处理的数据

### 2.1 截图与识别结果

当你使用截图、全屏截图、应用窗口截图、滚动截图、标注、贴图或文字提取功能时，本应用会在本机处理屏幕图像。截图默认保存为 PNG，路径为：

`~/Pictures/UDaSnap/`

文字提取使用 macOS Vision 在本机识别，识别结果只显示在结果窗和剪贴板中，不单独生成文本文件。

标注截图点“完成”或“贴图”时，只保存一张最终 PNG，不保存原图。马赛克、模糊和纯黑色块在导出时烘焙为最终像素，输出文件中不保留被遮挡区域的原始内容。

### 2.2 快捷键与 AI 配置

本应用在本机保存以下配置：

- `~/Library/Application Support/com.udalink.udasnap/settings.json`：五套快捷键和强力模式开关。
- `~/Library/Application Support/com.udalink.udasnap/ai-settings.json`：AI 接口地址、模型名称、提示词、识别模式和翻译方向。此文件不包含 API Key，也不保存隐私同意状态。
- `~/Library/Application Support/com.udalink.udasnap/compliance.json`：隐私政策版本、同意时间和截图保留期限。
- macOS 应用偏好 `UDaSnap.aiConsent.v1`：每个已同意过的 AI 接口地址 + 模型名称及首次同意时间；不保存截图、提示词、识别文字或对话内容。

### 2.3 API Key

API Key 只保存在 macOS 登录钥匙串的通用密码条目：service 为 `com.udalink.udasnap.ai`，account 为 `api-key`。它不写入 `ai-settings.json`，不会在界面中明文显示，也不会写入本应用的远程请求之外。

AI 识别、AI 翻译、测试连接和日常 AI 请求不会无条件读取钥匙串：App 先在本地静默检查当前构建的代码签名 cdhash 是否已在该条目的 ACL partition 列表中；只有已授权才读取 Key，未授权时直接按“未配置 Key”处理，不会弹出登录钥匙串密码框。打开 AI 设置页也不会自动读取 Key；只有你点「查看」时才允许一次系统授权读取。

自签名 App 每次重新编译或升级后 cdhash 会变化。当前构建第一次点「查看」时，macOS 可能要求一次钥匙串授权；在弹窗选「始终允许」后，当前构建的 cdhash 会加入该条目的 partition 列表，之后当前构建内 AI 日常使用可静默读取。选择「允许」而不是「始终允许」时，本次查看可以成功，但下次启动后 AI 仍不会弹窗，只会提示你先点「查看」授权。重新编译或升级后需要再授权一次。这是自签名方案的已知代价；若希望长期免授权，需要 Apple Developer ID 签名与 Data Protection Keychain。

旧版本曾使用的本地 Key 文件 `~/Library/Application Support/com.udalink.udasnap/api-key` 已不再写入或读取；升级后如仍存在，可手动删除，不影响钥匙串中的 Key。清除 API Key 会删除该钥匙串条目；清除应用配置也会删除它。

### 2.4 剪贴板

截图、滚动长图和文字提取结果会按功能设计写入系统剪贴板。本应用不读取剪贴板中的其他内容；剪贴板不会自动清空，是否清空由你决定。

### 2.5 临时文件

正式版本不会在 `/tmp` 写权限或快捷键诊断文件。仅在开发自检模式（`--self-test`）下，应用会在系统临时目录生成一张自检 PNG；正常使用不会生成，也不包含你的截图、识别文字或对话。

### 2.6 权限状态

本应用会读取 macOS 的屏幕录制和辅助功能授权状态，用于显示菜单栏提示和设置页状态，不会读取与截图无关的系统内容。

## 3. AI 外发与第三方服务

### 3.1 什么时候发送

只有你主动触发 AI 识别、AI 翻译或“小U”对话，并且已经配置接口时，本应用才会发起网络请求。普通截图、贴图、滚动截图和本地 OCR 不会联网。

### 3.2 发送什么

根据功能不同，可能发送：

- 当前截图（PNG 或压缩后的 JPEG，以 data URL 形式）；
- 系统提示词和当前识别模式；
- 当前识别结果或待翻译文字；
- 当前模式下的对话历史；
- 模型名称、请求参数和 API Key（仅在需要鉴权的请求头中）。

“测试连接”发送纯文本测试消息；“测试读图”发送一张内置测试图，不发送你的截图。

### 3.3 发送给谁

接收方是你自己在「AI 设置」中填写的 OpenAI 兼容接口。该接口可能由第三方运营，可能位于中国大陆境外。本应用无法控制第三方的数据留存、二次使用、跨境传输或安全措施；你应在使用前阅读该服务方的隐私政策，并只使用你信任的服务。

### 3.4 授权与撤回

首次启动时，你通过勾选同意本政策和《用户协议》，同意本应用按本政策处理数据和进行本地处理；这份总同意不覆盖向具体第三方 AI 接口发送数据。

在第一次向某个“接口 + 模型”发送 AI 请求前，应用会单独显示接口 host、模型和本次将发送的数据类型（截图、提示词、识别文字、对话等）；只有点击“同意并发送”才会发出，点“取消”不会传输任何数据。同意后，应用在 macOS 偏好 `UDaSnap.aiConsent.v1` 记录该接口、模型和同意时间；同一接口 + 模型后续不再重复弹窗。更换接口或模型会重新确认。

你可以在「隐私与数据」页随时撤回同意，撤回后应用立即停止截图和 AI 请求，并清除上述逐接口同意记录；也可以在 AI 设置或「隐私与数据」页清除配置，同样会清除记录。

## 4. 数据保存期限

- 截图：默认永久保存在 `~/Pictures/UDaSnap/`，直到你手动清理或在「隐私与数据」页设置 30 天 / 7 天保留期限。自动清理只删除该目录中符合 UDaSnap 命名规则的 PNG，不动其他文件。
- 快捷键、AI 配置和同意记录：保存在本机，直到你清除应用配置。
- API Key：保存在 macOS 登录钥匙串（service `com.udalink.udasnap.ai` / account `api-key`），直到你清除 API Key 或清除应用配置；钥匙串条目由系统加密保存。
- AI 对话：只存在于当前结果窗内，关闭窗口即清空，不写入磁盘。
- AI 服务方留存：由你选择的第三方接口决定，本应用无法删除对方持有的数据。

## 5. 数据共享、转让与公开

本应用不向任何广告商、数据经纪商或分析平台共享数据，不出售数据，不为了跨应用追踪而共享数据。

除以下情况外，本应用不会主动向第三方提供数据：

1. 你主动使用 AI 功能，数据发送给你配置的接口；
2. 你主动点击文档中的 GitHub 链接，由浏览器访问 GitHub；
3. 法律法规要求，或有权机关依法提出要求。

## 6. 数据安全

- API Key 保存在 macOS 钥匙串，不写入配置文件，也不落明文文件；AI 请求只在当前构建已授权时静默读取，未授权不读、不弹密码；自签名 App 每个新构建首次「查看」需授权一次，选「始终允许」。
- AI 请求使用临时 URLSession，不保留 Cookie、缓存或凭据存储。
- 应用不内置第三方统计 SDK、崩溃上报 SDK 或广告 SDK。
- 远程 AI 接口只允许 HTTPS，客户端会拒绝远程 `http://` 请求，避免 API Key、截图和提示词被明文发到公网；HTTP 仅允许 localhost、局域网地址和 `.local` 主机，且设置页会提示“未加密连接”。
- 屏幕录制权限允许本应用读取屏幕内容。请只在你主动截图时授予和保留该权限；不使用本应用时可在系统设置中关闭。

## 7. 你的权利

你可以：

- 查看本应用保存了哪些数据：在「隐私与数据」页查看数据位置和数量；
- 访问截图和配置：点击“打开截图目录”“打开配置目录”；
- 更正配置：在 AI 设置和快捷键页修改；
- 删除 API Key：在 AI 设置或「隐私与数据」页清除；
- 删除应用配置：在「隐私与数据」页清除，包含快捷键、AI 配置、Key、总同意和逐接口 AI 同意记录；
- 清理截图：在「隐私与数据」页删除 UDaSnap 截图；
- 撤回同意：在「隐私与数据」页撤回，撤回后回到首次同意页，并清除逐接口 AI 同意记录；
- 投诉或提问：通过 GitHub Issues 联系；涉及截图、Key、身份信息等敏感内容时，请使用仓库 Security 的私密报告，不要公开发布。

## 8. 未成年人

本应用不面向未满 14 周岁的儿童。若你未满 14 周岁，请在监护人陪同下阅读本政策并使用本应用。

## 9. 政策更新

本政策版本号会随实质性修改更新。若你已同意旧版本，而新版本发生实质变化，本应用会在启动时重新显示同意页。普通文字修正不触发重新同意。

## 10. 联系与争议

如对本政策或数据处理有疑问，请通过 UDaSnap 仓库的 GitHub Issues 联系项目维护者；敏感信息请使用 Security 私密报告。若争议无法协商解决，适用中华人民共和国法律，并由有管辖权的人民法院处理。

---

## English Summary

UDaSnap is a local-first macOS screenshot utility. Screenshots, scrolling capture, and OCR are processed on your Mac by default. AI recognition, translation, and chat are optional: only when you trigger them, the current screenshot, prompts, OCR text, and current chat are sent to the OpenAI-compatible endpoint you configure. Before the first request to each endpoint + model, the app separately shows the host, model, and data types and asks for consent; declining sends nothing. Remote endpoints must use HTTPS; HTTP is limited to localhost, LAN addresses, and `.local` hosts. The endpoint may be operated by a third party and may retain or transfer data across borders; review that provider's privacy policy before use.

API keys are stored only in the macOS Keychain and are not written to configuration files. The app has no telemetry, analytics, ads, crash reporting, or automatic update checks. Screenshots are stored in `~/Pictures/UDaSnap/` by default and can be deleted or auto-expired after 7 or 30 days. Configuration is stored in `~/Library/Application Support/com.udalink.udasnap/`. AI chat history is kept in memory only and is cleared when the window closes.

You can access, delete, or withdraw consent in the Privacy & Data settings page. The operator is the UDaSnap project maintainer; contact is available through GitHub Issues, and sensitive reports should use the repository's private Security advisory. This policy is primarily intended for users in mainland China and is governed by the laws of the People's Republic of China. The Chinese version prevails.
