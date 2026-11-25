# 开发

## 环境

- macOS 14+
- Swift 6.x，Xcode Command Line Tools 即可
- `swift format`（随 Swift 工具链或单独安装）
- 可选：`gh` 或 GitHub CLI，用于仓库与 Release 操作

检查：

```bash
swift --version
swift format --version
xcode-select -p
```

## 本地构建

```bash
swift build
swift build -c release
```

构建可执行位于 `.build/debug/UDaSnap` 或 `.build/release/UDaSnap`。

## 打包

```bash
bash ./build.sh            # dist/UDaSnap.app
bash ./build.sh install    # 安装到 /Applications
```

默认 ad-hoc 签名。需要固定证书时：

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" bash ./build.sh install
```

`bash ./build.sh install` 在默认 ad-hoc 模式下，会优先用本机已有的 `PinShot Local` 证书重新签安装版（仅 `/Applications`，不改变 `dist` 的分发签名）。这样本机 Screen Recording / TCC 的代码要求和后续 rebuild 保持稳定；ad-hoc 每次 cdhash 变化会让授权反复失效。没有该证书时跳回 ad-hoc。

若系统设置里已有旧的 UDaSnap 条目或授权残留，先清理当前 bundle 的屏幕录制记录再授权：

```bash
tccutil reset ScreenCapture com.udalink.udasnap
```

`build.sh` 会：

1. 构建 Universal release（arm64 + x86_64）；
2. 组装 `.app`；
3. 写入 `Info.plist`（bundle id `com.udalink.udasnap`，版本 `1.2.0` / `9`）；
4. 复制图标和 `PRIVACY.md`、`TERMS.md` 到 `Contents/Resources/Legal/`；
5. `codesign` 并验证。

## 测试

```bash
swift test
```

测试只覆盖 `UDaSnapCore`，包括标注模型的编号、撤销/重做、裁剪、旋转、翻转与命中测试。本机仅安装 Command Line Tools 时可能没有 XCTest；以 GitHub Actions 的 macOS runner 结果为准。

## 格式

仓库根目录的 `.swift-format` 是格式基线：

```bash
swift format lint -r Sources Tests
swift format format -i -r Sources Tests
swift format lint -r Sources Tests Package.swift
```

CI 会执行 `swift format lint`，格式不一致会使检查失败。

## 冒烟

```bash
.build/debug/UDaSnap --self-test
```

该模式只截取主屏并打印尺寸、权限与保存路径，不弹窗，不启动常驻菜单栏。正常启动：

```bash
open dist/UDaSnap.app
```

手动检查：

- 菜单栏图标出现；
- 六个热键可触发对应流程：立即截图、贴图、框选、全屏、应用窗口、滚动；OCR 与标注没有全局热键；
- 菜单“标注截图”位于“文字提取 - AI 分析”下面；标注编辑器可打开，工具、样式、撤销/重做、文字、裁剪、旋转、翻转、隐私遮挡可用；
- 框选保存、应用窗口截图、全屏截图保存后出现右下角缩略图，悬浮显示四角操作，点击主体进入标注；
- 贴图悬浮显示四角操作与右侧外部 OCR / AI / 翻译按钮；
- 偏好设置快捷键页只有五项，按菜单顺序排列：贴图、框选、全屏、应用窗口、滚动；旧 `settings.json` 缺少 `fullScreenKeyCode` 时五键一次性重置，`annotationKeyCode`、`ocrKeyCode` 等废弃字段被删除；
- “完成”与“贴图”都能复制、保存最终 PNG，并确认 PNG 方向与像素尺寸；
- 截图保存到 `~/Pictures/UDaSnap/`；
- 偏好设置三页可打开；
- 首次启动同意页与逐接口 AI 同意正常；
- 退出后无残留进程。

## 代码约定

- Core 不出现 `import AppKit` / `import Carbon`。
- 新类型按职责命名：`Service`、`Store`、`Client`、`Policy`、`WindowController`、`View`；避免泛化 `Manager` 和重复产品前缀。
- 注释与 DocC 用英文；界面文案与 README 用中文。
- 不提交 `.build/`、`dist/`、`*.zip` 或签名产物。
- 提交信息用祈使句，说明“为什么”而不是只列文件。

## CI / Release

- `.github/workflows/ci.yml`：push / PR 跑 `swift build`、`swift test`、`swift format lint`。
- `.github/workflows/release.yml`：`v*` tag 或手动触发，构建 Universal `.app`，打包 zip，生成 `SHA256SUMS.txt`，上传 Release 资产。

发布前确认：

```bash
bash ./build.sh
codesign --verify --deep --strict dist/UDaSnap.app
spctl -a -vv dist/UDaSnap.app   # ad-hoc 构建预期 rejected
```
