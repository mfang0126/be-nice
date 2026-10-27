# be-nice — agent 指南

macOS 菜单栏 App：把用户在 Slack 里写好的草稿改写成 1–3 个完整版本，用户确认后替换回原输入框，可撤销。当前只做 Slack 桌面版 MVP。

## 先读什么

1. [STATUS.md](STATUS.md)：当前阶段、卡点、下一步。
2. [PLAN.md](PLAN.md)：已确认的决策和 S0–S4 验收标准，唯一计划来源。
3. [GLOSSARY.md](GLOSSARY.md)：术语。
4. 要用 LCU 做真实界面测试且你**不是 Opus 5.5**：先读 [docs/research/lcu-gui-testing.md](docs/research/lcu-gui-testing.md)（Opus 5.5 不用读）。
5. 需要时再看 `docs/research/`（当前证据）、`docs/archive/`（历史，不是待办）、`mac-app/README.md`（构建和测试命令）。

## 硬规则

- **范围**：只做 PLAN 里已确认的事。新功能、新工具、新诊断宿主，先问用户并写进 PLAN，再动手。
- **git**：禁止 `reset` / `restore` / `stash` / `clean`；commit 和 push 需用户授权。只在本 worktree 工作，不回主 checkout `~/Projects/be-nice`。
- **真实测试**：只用专用合成草稿；不碰已有草稿，不发送消息。前台操作只在用户明确交出的测试时段进行。原生 UI 用 LCU，浏览器用 Kimi WebBridge，不抢鼠标。
- **凭据**：不打印、不写进仓库或 worker 说明；不覆盖 App 里已有的模型配置和 Keychain。
- **权限**：不重置 TCC、不改 TCC.db、不用 DEBUG 假装有权限。
- **验收**：诊断、编译、模拟测试通过都不算交付；Slack 能力以真实读回为准。每个功能块做完，由另一个 agent 独立 review。
- **文档**：STATUS 覆盖重写不追加；决策改动写 PLAN；不新建并行的计划或交接文件。

## 代码地图

- `mac-app/Sources/benice/`：App 源码。`WriteBack.swift` 安全写回核心；`OptimizerController.swift` 主流程；`RewriteWindowController.swift` 改写 UI；`TriggerController.swift` 焦点追踪和屏幕边缘入口；`SlackDiagnostic.swift` 只读诊断。
- `mac-app/*Tests.swift`、`mac-app/*Tests.py`：独立 selftest，不走 `swift test`。
- `mac-app/scripts/`：构建、签名、权限和诊断脚本。

## 验证

```sh
sh mac-app/scripts/run-tests.sh            # 编译 + 全部 selftest（Swift 与 Python）
sh mac-app/scripts/check-dev.sh            # 编译 + 权限 selftest + 签名/状态脚本检查
sh mac-app/scripts/check-dev.sh --runtime  # 另查运行中 App 的真实 Accessibility 权限
sh mac-app/scripts/build-app.sh debug --install   # 构建并安装开发版（先正常退出旧版）
```
单项测试的 swiftc 命令见 `mac-app/scripts/run-tests.sh`（`run-tests.sh` 跑全部）。

## 多 agent 分工（Orca）

- 协调者（Opus）负责接口、安全核心（WriteBack、焦点、取消、Keychain）、真实 GUI 测试和集成；GUI 与付费模型请求只由协调者串行执行。
- 边界清楚的实现和独立 review 派给 Sonnet；机械检查、证据整理派给 Haiku。
- 同时最多两个实现 worker，一个文件同一时刻只有一个 owner。派活说明写明：目标文件、改动、禁止事项、验收命令。
- worker 遇到范围外修改或同一检查连续失败两次，停下来报告，不自行扩大范围。
