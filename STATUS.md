# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-27 00:35 AEDT

## 阶段：S0 Slack 能力探测（进行中）

已证实（[S0 记录](docs/research/slack-s0-2026-10-26.md)，Slack 4.52.182，`com.tinyspeck.slackmacgap`）：
- 自己私聊的普通输入框是 `AXTextArea`，AXValue / SelectedText / SelectedTextRange 均可写。
- 用 LCU 写入合成文本：英文替换、恢复、中文多行均精确读回；测完已恢复为空，未发送。
- 这不是产品验收：写入走的是 LCU，不是 be-nice 的写回事务。

卡点（S0 未过，不能进 S1）：
1. **会话身份**：私聊 URL 以 `/dms` 结尾不唯一，显示名/窗口标题/输入框描述都不可靠；诊断上溯 8 层全是 AXGroup。`contextIdentityVerified` 仍为 false。
2. **富内容**：emoji 是 AXImage 子元素，不在 AXValue 里。需检查输入框子元素，或遇到时拒绝直接替换。

## 代码现状

- 改写窗口 10-26 按设计 B「并排对比」重做（`RewriteWindowController`）：三张卡片并排显示全文，点选即可编辑，底栏主按钮替换，可见撤销不变；“想怎么改”输入框已留位置（隐藏）。经独立 review，修了输入法 Esc、处理中卡死、VoiceOver 三处问题。只做过后台截图和单元测试，**未在真实窗口验收**（遮罩、长原文滚动条待确认）。
- 安全写回核心 `WriteBack.swift`：目标复核、单次写入、独立读回、possible-write 恢复。
- Slack **未**加入 allowlist；`SlackDiagnostic.swift` 是只读、不含正文的诊断。
- 个人风格学习代码保留但已从 UI 摘除（后置）。旧小绿点卡片、多 App 探针已删除，可从标签 `archive/multi-app-m0-m2` 找回。
- `MenuBarShell.swift` 的诊断结果乱序保护已于 10-26 补做独立 review，无高置信问题；已知小缺口：最新一次诊断失败时会留下旧结果文件，调用方须核对 requestID。

## 开发环境

- 开发版固定路径 `~/Applications/be-nice Development.app`，Bundle ID `com.benice.menubar.development`，本地签名证书指纹 `D933388477455C8C62344293E483E625F4B7B194`（不得重新生成）。
- 10-26 00:03 用户已授予 Accessibility；10-27 00:30 重建安装新版（并排对比窗口）后，运行中的 App 报告 `accessibilityTrusted: true`，**重建后授权保留已验证**。使用前跑 `python3 -I mac-app/scripts/debug-status.py`（0=已授权，2=未授权，1=无法确认）。
- App 里已配置真实 DeepInfra endpoint/model：测试不得覆盖用户配置或 Keychain。

## 下一步

1. 找到能唯一确认 Slack 会话的 AX 依据（需要用户交出前台测试时段）。
2. 决定富内容的识别方式（检查子元素或拒绝）。
3. 两项有结论后进入 S1：Slack 安全写回与撤销。
