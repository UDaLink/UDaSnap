# 贡献指南

感谢你愿意改进 UDaSnap。提交前请先确认改动符合“功能与 1.6.1 等价、只重构代码、明确 bug 可修”的边界。

## 流程

1. 从 `main` 建一个短期分支：`fix/...`、`refactor/...` 或 `docs/...`。
2. 本地运行：

   ```bash
   swift build
   swift format lint -r Sources Tests
   ```

3. 如改动 Core，请补或更新 `Tests/UDaSnapCoreTests`。
4. 提交 PR，说明动机、行为变化、验证方式；不要提交 `.build/`、`dist/`、zip 或签名产物。

仓库不保留长期 `dev` 分支；合并后删除功能分支。

## 代码边界

- `UDaSnapCore` 不得 `import AppKit` 或 `import Carbon`。
- AppKit、Carbon、窗口、剪贴板和权限 UI 只在 `UDaSnap` App target。
- 不引入第三方依赖，除非在 PR 中说明必要性、许可证与体积影响。
- 新类型按职责使用 `Service / Store / Client / Policy / WindowController / View` 后缀；避免 `Manager` 和重复产品前缀。
- 注释与 DocC 用英文，界面文案与文档用中文。

## 隐私与安全

- 不要在日志、测试或示例中写入 API Key、真实截图或用户配置。
- 新增网络请求必须走 `AIEndpointPolicy`；远程 HTTP 必须拒绝。
- 新增持久化字段要说明是否包含个人信息、保存位置和删除路径。
- 发现安全问题请按 [SECURITY.md](SECURITY.md) 私密报告，不要开公开 Issue。

## 文档

用户可见行为变化同步更新 `README.md`、`docs/USAGE.md`；架构变化同步 `docs/ARCHITECTURE.md`；版本变化更新 `CHANGELOG.md` 和 `docs/DEVELOPMENT.md` 的版本说明。
