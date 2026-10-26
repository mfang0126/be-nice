# 历史跨 App 能力矩阵与参考（2026-10-23 至 10-24，已归档）

> 从 PLAN.md 移出。MVP 已收敛为 Slack，本文件只作历史证据，不是待办。文中链接的 m0-*.md 与本文件同在 docs/archive/。

本轮环境：macOS 26.6.2 (25G83)，2026-10-23 至 2026-10-24。`环境阻断` 表示目标发现/观察阶段受阻，未测到真实控件；`未测` 表示该能力尚未实际执行。两者都不构成支持或不支持结论。可用目标的 M0 能力矩阵及 M1 产品闭环已完成；Slack 环境阻断、浏览器/专用 Electron 的 SelectedText 未确认等原始条目仍按下表保留，不视为全目标全能力验收完成。定位列当前仅指 AXSelectedTextRange 设置；屏幕坐标读取尚未验证。运行证据见 [10-23 记录](./m0-runtime-2026-10-23.md) 和 [10-24 记录](./m0-runtime-2026-10-24.md)。写回须分别验证 AXValue 与 AXSelectedText；剪贴板保护单列。

| 目标 / 版本 | 读选区 | 读全文 | 定位 | 写回 Value / SelectedText | undo | 焦点保持 | 剪贴板保护 | 备注 |
|------|--------|--------|------|------|------|----------|----------|------|
| TextEdit 1.20 (415) | 空/全选/局部选区通过 | 通过 | 全选恢复及局部范围 20,5 通过 | 通过（含恢复） / 局部 hello→HELLO 通过 | Value 与 SelectedText 各单次 Cmd-Z 后读回原文 | 通过 | 本次 changeCount 不变 | ASCII 固定 fixture；Unicode/IME/富文本未测；见 10-24 记录 |
| Notes 4.13 | 空/局部选区通过 | 通过 | 范围 0,3 及局部 20,5 通过 | 通过（含恢复） / 局部 hello→HELLO 通过（含恢复） | Value 与 SelectedText 各单次 Cmd-Z 后读回原文 | 通过 | 本次 changeCount 不变 | 专用新建 note、ASCII fixture；Unicode/IME/富文本格式未测；见 10-24 记录 |
| Safari 26.6.2 input | 空选区通过 | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未通过） | 通过 | 本次 changeCount 不变 | 本地 ASCII fixture；undo 不作支持/不支持结论；见 10-24 记录 |
| Safari 26.6.2 textarea | 空选区通过 | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未通过） | 通过 | 本次 changeCount 不变 | 同上 |
| Safari 26.6.2 contenteditable | AXSelectedText 不可用（-25212） | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未通过） | 通过 | 本次 changeCount 不变 | 同上；未验证富文本格式保留 |
| Chrome 156.0.8078.47 input | 空选区通过 | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未建立） | 通过 | 本次 changeCount 不变 | 本地 ASCII fixture；undo 不作支持/不支持结论；见 10-24 记录 |
| Chrome 156.0.8078.47 textarea | 空选区通过 | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未建立） | 通过 | 本次 changeCount 不变 | 同上 |
| Chrome 156.0.8078.47 contenteditable | 空选区通过 | 通过 | 范围 0,3 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | 未验证（键盘正向对照未建立） | 通过 | 本次 changeCount 不变 | 同上；未验证富文本格式保留 |
| Slack 桌面（版本待确认） | 未测 | 未测 | 未测 | 未测 / 未测 | 未测 | 未测 | 未测 | 标准安装路径及 Spotlight 未找到；防假成功 |
| VS Code 1.142.0 纯文本编辑器 | 空选区通过；局部 hello 可读 | 通过 | 范围 0,3 通过；局部 20,5 首次读回不一致、复测通过 | 500ms 内未确认 / 局部写未确认 | 未执行（无已确认写入可撤销） | 通过 | 本次 changeCount 不变 | 专用 /tmp 纯文本 fixture；Value 500ms 内未观察到生效；SelectedText 即时及后续读取未确认，暂不纳入可写支持；未测集成终端；见 10-24 记录 |
| Terminal 2.15 (470.2) | 策略阻断 | 策略阻断 | 策略阻断 | 策略阻断 / 策略阻断 | 不执行 | 不执行 | 不执行 | CLI 实测 BLOCKED_EXCLUDED_APP；在发现焦点前排除，未读写命令行 |
| Electron 33.4.11 input | 读取通过 | 通过 | 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | AXValue 后单次 Cmd-Z 未恢复 | 通过 | 本次 changeCount 不变 | 异步写需等待；SelectedText 超时 FAIL，不认定永久无效；AXValue 原生 undo 未通过；含按键正向对照 |
| Electron 33.4.11 textarea | 读取通过 | 通过 | 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | AXValue 后单次 Cmd-Z 未恢复 | 通过 | 本次 changeCount 不变 | 同上；仅固定 fixture；AXValue 原生 undo 未通过；含按键正向对照 |
| Electron 33.4.11 contenteditable | 读取通过 | 通过 | 设置及恢复通过 | 通过（含恢复） / 500ms 内未确认 | AXValue 后单次 Cmd-Z 未恢复 | 通过 | 本次 changeCount 不变 | 同上；未验证富文本格式保留；AXValue 原生 undo 未通过；含按键正向对照 |

## 参考实现

- WritingAssistant（选区浮层与粘贴策略）、Selara（目标复核）——README 不是可靠性证明，复用前审代码与许可证。
- TypeTide：AX 读选区 + 剪贴板兜底 + 粘贴回原处保 undo；已知限制：部分 app 无选区/文本边界接口、剪贴板管理器可能留下历史记录。
- Raycast AI Commands / Grammarly Desktop：公开资料证明"AX + 粘贴"路线存在，内部实现未公开。

## 评审证据

- `./review-1-plan-risks.md` — 计划技术风险评审（deleg_73b4e599）
- `./review-2-ax-facts.md` — AX/NSPanel 实证事实（deleg_4764e1fb）
- `./review-3-local-model.md` — 本地小模型调研（deleg_6a833a52）
