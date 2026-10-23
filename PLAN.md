# be-nice — 实施计划 v3（MVP 收敛版）

> 原计划：`mac-text-optimizer-plan.md`（2026-10-23）。v2 根据两轮独立评审重排；v3 把模型层改为 OpenAI 兼容协议，本地模型降为 optional。
> 原则不变：先能用，再好看；先有个人风格，再加模板；不 overkill。

## v3 变更
- **LLM 接入只认 OpenAI 兼容协议**（`/v1/chat/completions`）：base URL + API key + model 名三个配置项。任何 OpenAI 兼容服务（官方、中转、本地 Ollama/LM Studio/llama.cpp server）都能接——同一个协议，不需要 provider 特判。
- **本地小模型（llama.cpp 嵌入、Qwen GGUF）整体后置为 optional**，不再是 MVP 依赖。`docs/research/review-3-local-model.md` 保留作未来本地档参考。
- 附带收益：引擎层砍掉嵌入式推理、模型下载、GGUF/许可证分发问题，MVP 明显变小。

## 关键修订（相对原计划）

1. **"任意输入框可安全读写"不是已验证前提**。读、定位、写 Value、换 SelectedText 是四种独立能力；API 返回 success 不等于真的写进去了（Slack 有假成功案例）。→ 用 M0 探针实测，出**支持矩阵**。
2. **浮层按钮不是第一步**。它技术坑最多（焦点、坐标、全屏、多屏），但不是价值验证点。→ 推迟到 M3。
3. **写回安全 > 功能**。LLM 请求期间用户继续打字/切窗口时绝不能误写。→ 写回状态机 + 目标复核是 MVP 必需，不是"以后"。
4. **快捷键 + 显式选区**是可靠入口，比浮层按钮先做。
5. **本地小模型是默认 provider**，不是附加项（隐私是核心卖点）。

## 里程碑

### M0 — 壳 + 权限 + 写回探针（不调 LLM）
- Swift + AppKit 菜单栏应用（LSUIElement），关 App Sandbox。
- Accessibility 权限引导（AXIsProcessTrustedWithOptions；注意提示异步、需复查/撤销处理）。
- **跨应用读写探针**：对固定测试文本，在 TextEdit、Notes、Safari/Chrome（input/textarea/contenteditable）、Slack、VS Code、Terminal（验证应被排除）逐一测：读选区、读全文、定位、写回、undo、焦点保持、剪贴板保护。
- 产出：**支持矩阵**（按 app/控件类型/版本），决定产品承诺范围。
- 分发决策：Developer ID 签名 + 公证（站外分发必须）。

### M1 — 浮层入口 + 快捷键 + 选区改写写回（价值兑现）
- **浮层小圆点是主入口**：在聚焦输入框旁出现、点击即优化。没有它工具难用，所以从 M3 提前进 MVP；快捷键作为等价备用入口一起做。
- **两种触发模式都支持**（做在同一个写回核心上）：
  - **有选区**：改选中文字，替换选区；
  - **无选区**：改整框内容，整体写回（写回前复核，覆盖范围更大，防误写要求更严）。
- LLM 走 OpenAI 兼容协议：配置 base URL + API key + model（Keychain 存 key）；失败不自动切换到别的服务。
- 写回状态机：idle → reading → requesting → validating → writing → verified/failed；每目标单请求、丢弃旧响应；写回前复核 PID+元素+原文+选区；空输出/截断/拒绝不替换。
- 预览/差异 + 撤销（原文保留到确认为止）。
- 剪贴板兜底（如需）：保存多 item 多类型、比较 changeCount、延迟恢复。
- 排除清单：Terminal、密码框、Secure Input 状态下停止。
- 验收：支持矩阵内 app 全过；验收重点是**没有误写**，不是 API 返回成功。
- **浮层实现要点**（进 M1，原 M3 内容）：
  - NSPanel + nonactivatingPanel + **becomesKeyOnlyIfNeeded=true**（否则点击会抢键盘焦点）；canBecomeKey=false（纯点击按钮）。
  - AXObserver 按 PID 建立（system-wide 对象不支持通知）；NSWorkspace 监听前台切换；AXUIElementSetMessagingTimeout 防卡死。
  - 坐标：AX 全局坐标（原点在菜单栏屏左上）→ AppKit 转换，锚点 NSScreen.screens[0]；多屏/负坐标/缩放。
  - 全屏可见性：collectionBehavior + level 逐版本测试，不承诺"永远最前"。
  - 只对支持矩阵内的目标显示。

### M2 — 风格学习 + 融入
- 设置页：手动粘贴 Slack 消息 → LLM 提炼结构化风格（可编辑，区分中/英、同事/客户）→ 预览确认。
- 风格进 prompt 时与原文隔离（原文是待处理数据，不覆盖系统指令）。
- 用保留样本对比"通用改写 vs 个性化改写"，盲评。
- 隐私：样本不出机器（本地模型）；若用远程须明示。

### M3 — 兼容扩展 + 发布
- 矩阵外 app 适配、Windows 壳（UI Automation，独立工作流）。
- 签名公证、最低 macOS 版本、崩溃/日志本地化（不上传原文）。
- 自动 Slack 抓取、多模板、本地/远程自动切换、历史库——继续后置。

## 模型接入（v3 定案）

- **协议**：OpenAI 兼容 `/v1/chat/completions`。配置三件套：base URL、API key（Keychain）、model 名。
- 本地模型 optional：任何本地服务只要暴露 OpenAI 兼容端点（Ollama、LM Studio、llama.cpp server）即天然可用，无需专门开发。
- 未来"嵌入式本地模型"（llama.cpp + Qwen GGUF）如需再启，调研结论见 `docs/research/review-3-local-model.md`。

## 验收矩阵（M0 产出，M1/M3 复用）

| 目标 | 读选区 | 读全文 | 定位 | 写回 | undo | 焦点保持 | 备注 |
|------|--------|--------|------|------|------|----------|------|
| TextEdit | | | | | | | 基线 |
| Notes | | | | | | | |
| Safari input/textarea | | | | | | | |
| Safari contenteditable | | | | | | | |
| Chrome input/textarea | | | | | | | |
| Chrome contenteditable | | | | | | | |
| Slack 桌面 | | | | | | | 防假成功 |
| VS Code | | | | | | | |
| Terminal | | | | | | | 应排除 |

## 参考实现

- WritingAssistant（选区浮层与粘贴策略）、Selara（目标复核）——README 不是可靠性证明，复用前审代码与许可证。
- TypeTide：AX 读选区 + 剪贴板兜底 + 粘贴回原处保 undo；已知限制：部分 app 无选区/文本边界接口、剪贴板管理器可能留下历史记录。
- Raycast AI Commands / Grammarly Desktop：公开资料证明"AX + 粘贴"路线存在，内部实现未公开。

## 评审证据

- `docs/research/review-1-plan-risks.md` — 计划技术风险评审（deleg_73b4e599）
- `docs/research/review-2-ax-facts.md` — AX/NSPanel 实证事实（deleg_4764e1fb）
- `docs/research/review-3-local-model.md` — 本地小模型调研（deleg_6a833a52）
