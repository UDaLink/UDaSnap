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

`build.sh` 会：

1. 构建 Universal release（arm64 + x86_64）；
2. 组装 `.app`；
3. 写入 `Info.plist`（bundle id `com.udalink.udasnap`，版本 `1.0.0` / `1`）；
4. 复制图标和 `PRIVACY.md`、`TERMS.md` 到 `Contents/Resources/Legal/`；
5. `codesign` 并验证。

## 测试

```bash
swift test
```

测试只覆盖 `UDaSnapCore`。本机仅安装 Command Line Tools 时可能没有 XCTest；以 GitHub Actions 的 macOS runner 结果为准。

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
- 五个热键可触发对应流程；
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
