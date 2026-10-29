# 零权限模式（辅助功能改为可选）— 设计

> 状态：原型（2026-10-29），未经真实 App 验证。实测步骤见 [no-ax-mode-user-test.md](no-ax-mode-user-test.md)。
> 用户 2026-10-29 认可的形态：授权了就走现有一键流程；没授权走 A 服务菜单，A 不能原地替换的 App 走 B 剪贴板。不做输入法、Slack 应用、斜杠命令、浏览器扩展。
> 用户 2026-10-29 追加三个决定（见「决定」）：只在 Slack 可用；只用默认风格；富内容拒绝。

## 结论

- **有辅助功能**：不变。pill 贴输入框，AX 读、写、读回、产品内撤销（`WriteBack.swift`）。
- **没有辅助功能**：
  - **A 服务菜单**：选中草稿 → 系统「服务」菜单里的 “Rewrite with Be Nice”（或用户自己在系统设置配的快捷键）→ 原地替换。撤销用宿主 App 的 ⌘Z。
  - **B 剪贴板**：⌘A ⌘C → ⌃⌥⌘Space → 改写结果放进剪贴板，鼠标旁 pill 提示 “Copied — press ⌘V” → 用户 ⌘V。pill 上的 Undo 把改写前的剪贴板（就是原草稿）原样放回。
  - pill 不知道输入框位置，改为跟着鼠标。
- 两条路径都**只在 Slack 里可用**，**没有 1–3 选 1**（用第 1 个风格槽），**带链接、@提及或格式就拒绝**（见「决定」）。
- 代码复用：模型配置、Copilot/自定义 provider、风格槽、提示词全部走 `OptimizerController.client(for:store:)` 和 `ModelClient.rewriteOptions`，没有复制。

## 现状（读代码得到）

- 触发：`TriggerController` 用 PID 级 AXObserver 跟踪焦点，屏幕边缘出 Rewrite 圆点；`RegisterEventHotKey` 注册 ⌃⌥⌘Space（Carbon 热键本身**不需要**辅助功能）。圆点和快捷键都先抓 AX target，`AXIsProcessTrusted()` 为假时什么都不做。
- 读写：`OptimizerController.trigger` → `WriteBackController.prepare`（AX 读整段原文）→ 模型 → 改写窗口 → `apply`（复核目标后一次写入 + 独立读回）。
- 撤销：`WriteBackController.undo`，复核当前值等于写入值后写回原文；pill 和菜单 “Undo Last Replace”。
- 权限引导：`MenuBarShell` 每 2 秒轮询 `AXIsProcessTrusted()`，`AccessibilityTracker` 分 denied / granted / revoked；菜单项 “Request Accessibility Access…” 调 `AXIsProcessTrustedWithOptions(prompt)`。App 启动时不强制弹框，但没授权就完全用不了。

## 模式判定

- `AccessMode(trusted: AXIsProcessTrusted())`：`.accessibility` / `.noAccessibility`。每次按快捷键时现查，授权或撤销立即生效，不用重启。
- 快捷键：`TriggerController.fireFromShortcut` 现查 `AXIsProcessTrusted()`，为假时调 `onShortcutWithoutAccessibility`（走 B），为真时走原流程。同一个快捷键，用户不用记两个。
- 服务菜单（A）**始终注册**，有没有授权都能用；有授权时它只是多一个入口。
- 两条路径执行前先过 `NoAXController.refusal`：前台 App 不在 Slack 白名单 → 拒绝；带富内容 → 拒绝（见「决定」）。
- revoked（授权过又被撤销）同样退到零权限模式，菜单文案说明。

## A：系统「服务」菜单

- `Support/Info.plist` 的 `NSServices`：`NSMessage = rewriteText`，`NSSendTypes` = 纯文本 + `public.rtf` + `public.html`（多要两种只为看出富内容，看到就拒绝），`NSReturnTypes` = 纯文本，`NSRequiredContext = {}`（默认启用），`NSTimeout = 60000` ms。**不设 `NSKeyEquivalent`**：默认快捷键留空，用户在 系统设置 → 键盘 → 键盘快捷键 → 服务 → 文本 → “Rewrite with Be Nice” 里自己配，避免和宿主 App 冲突。开发版由 `build-app.sh` 改成 “Rewrite with Be Nice (Dev)”，`NSPortName` 跟 `CFBundleName` 一致。
- 启动时 `NSApp.servicesProvider = NoAXController`，再 `NSUpdateDynamicServices()`。
- 数据流：宿主把选区写到服务专用 pasteboard → `rewriteText(_:userData:error:)` → `handleService`：上一次还在跑就拒绝（等待时的 run loop 可能收到第二个服务调用）；不在 Slack 或带富内容就拒绝；空选区直接报错；否则鼠标旁 pill “Rewriting…”（可 Cancel），在后台任务里调 `OptimizerController.firstRewrite`，主线程转 run loop 等结果（服务调用是同步的，55 秒自限，低于 60 秒 NSTimeout）→ 成功写回服务 pasteboard，宿主替换选区；失败设 `error`，宿主不替换。
- **不碰用户的通用剪贴板**（服务用的是独立 pasteboard）。
- 撤销：宿主 App 的 ⌘Z。Cocoa 文本框（TextEdit 等）会把服务替换记进撤销栈；Electron/Chromium 是否支持服务的**写回**（`readSelectionFromPasteboard`）以及 ⌘Z 是否能撤回，都**未验证**，是用户实测的重点。
- 富内容：已拒绝，提示 “Copy it and press ⌃⌥⌘Space, or enable one-click mode.”（见「决定」3）。

## B：剪贴板 + 全局快捷键

- 先过 `refusal`：不在 Slack → “Be Nice works in Slack only; nothing was changed.”；剪贴板带富内容 → “…Enable one-click mode (Accessibility) to rewrite it.”。都不读模型、不改剪贴板。
- `ClipboardRewriter.run()`：读通用剪贴板的字符串；为空就提示 “Copy your draft first (⌘A ⌘C)…”，**不调模型**。否则先把剪贴板所有 item 的所有类型存进内存（`PasteboardSnapshot`），记下 `changeCount`，调模型。
- 模型返回后，如果 `changeCount` 变了（用户等待期间又复制了别的），**不写**，报 “The clipboard changed…”。否则写入改写结果，记下写后的 `changeCount`。
- pill：“Copied — press ⌘V”＋Undo。
- 撤销（恢复原剪贴板）：只有剪贴板仍是我们写的那份（`changeCount` 没变）才恢复全部原类型，一次性；用户之后复制了别的就拒绝，绝不覆盖用户新复制的内容。已粘贴进输入框的文字靠宿主 ⌘Z。
- 快照只在内存里，下次运行或恢复后丢弃，不落盘。

## 首次引导文案（不再强制要权限）

- 菜单状态行：授权 → “Accessibility: Granted”；没授权 → “Clipboard mode — no Accessibility needed”；撤销 → “Accessibility revoked — using clipboard mode”。
- 原 “Request Accessibility Access…” 改为 **“Enable One-Click Mode (Accessibility)…”**，作为升级选项，不是前置条件。
- 快捷键行：没授权时显示 “Copy your draft, press ⌃⌥⌘Space, then ⌘V”。
- README 的 Setup 第 4 步需要改成可选（本 PR 未改，等实测结论后再定文案）：
  > 4. Optional: grant **Accessibility** for one-click replace inside Slack. Without it, select your draft and use **Services → Rewrite with Be Nice**, or copy it (⌘A ⌘C), press ⌃⌥⌘Space and paste (⌘V).

## 对隐私承诺的影响

- 不变：只在用户主动触发时发送草稿；没选 provider 前什么都不发；没有自己的服务器。
- 变好：零权限模式下 App 看不到任何 App 的界面结构和输入框，只拿到用户主动选中或复制的那段文字。
- 新增要写清的一点：B 会**读通用剪贴板**，仅在按快捷键那一刻读一次；会**写剪贴板**（改写结果），并在内存里临时保留原剪贴板以便恢复。剪贴板管理器会记录这次写入。
- macOS 的剪贴板隐私：Apple 在 macOS 15.4 预告，程序在非用户粘贴动作下读通用剪贴板时系统会弹 “允许粘贴” 提示，并加了 `NSPasteboard.accessBehavior` 和 detect 系列 API（[MacRumors](https://www.macrumors.com/2025/05/12/apple-mac-apps-clipboard-change/)，[Michael Tsai 汇总](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4)）。macOS 26 是否默认开启有争议（同页评论称需 defaults 手动开）。B 的快捷键读取不算系统认可的粘贴动作，**可能触发一次系统提示**，需实测。A 不受影响。

## Mac App Store 沙盒

- **AX 路径不行**：Apple DTS 明确 “We do not support the Accessibility APIs in sandboxed apps”，沙盒内 `AXIsProcessTrusted()` 恒为假、不出授权框（[Apple Developer Forums 810677](https://developer.apple.com/forums/thread/810677)）。
- **零权限模式理论上可行**：服务提供方（NSServices）、`RegisterEventHotKey`、读写 `NSPasteboard.general` 都不属于沙盒禁用的能力，已有 MAS 上架的剪贴板/文本服务类 App 用这些 API。我没找到 Apple 文档逐条确认这三项在沙盒内的行为，结论属于“推断，需在沙盒构建里验证”。网络请求需 `com.apple.security.network.client`；Copilot 路径调用 `gh` 子进程在沙盒内**不可行**，MAS 版只能用自定义 API key。
- 所以：MAS 版 = 只有零权限模式 + 自定义 API；直接下载版 = 两种模式都有。现在不做 MAS 构建。

## 代码改动（本 PR）

- `OptimizerController.swift`：抽出 `client(for:store:)`（原 `start` 里的 switch，行为不变）和 `firstRewrite(_:)`。
- `NoAXMode.swift`（新）：`AccessMode`、`HandoffError`、`PasteboardSnapshot`、`ClipboardRewriter`（B）、`NoAXController`（A 的服务处理函数 + B 的入口 + 鼠标旁 pill）。
- `TriggerController.swift`：快捷键在没授权时转给 `onShortcutWithoutAccessibility`。
- `MenuBarShell.swift`：注册服务、接上 B、改菜单文案。
- `StatusPill.swift`：两条新成功文案按成功样式显示。
- `Support/Info.plist`、`scripts/build-app.sh`：NSServices；开发版改名。
- `NoAXModeTests.swift`（新，进 `run-tests.sh`）：模式判定；三个决定（Slack 外 A/B 都拒绝且不调模型、富类型/链接/提及拒绝而纯文本+元数据放行、默认取第 1 个风格）；B 的写入、全类型恢复、一次性恢复、新复制不被覆盖、等待期间剪贴板变化不写、空剪贴板不调模型；A 的成功输出、模型报错不替换、空选区、超时不替换。只用私有命名 pasteboard，不碰用户剪贴板。
- 没碰 `SettingsWindow.swift`、`WriteBack.swift`。

## 决定（用户 2026-10-29）

1. **只在 Slack 可用**：沿用 `TriggerPolicy.wholeValueBundleIDs`（只有 Slack），用 `NSWorkspace.shared.frontmostApplication` 判断，不需要权限。服务调用时前台就是发起调用的 App。其他 App 里触发：鼠标旁 pill “Be Nice works in Slack only; nothing was changed.”，不发模型请求，不改任何文字。这也挡住了“任意本机程序借 Be Nice 调用户模型”的一部分风险。
2. **只用默认风格**：`HandoffPolicy.defaultRewrite` 取第 1 个风格槽，不弹 1–3 选择。
3. **富内容拒绝**（A、B 同一判断 `HandoffPolicy.isRich`）：
   - pasteboard 上有格式类型：`public.rtf`、`public.rtfd`、`public.html`、`com.apple.flat-rtfd`、`com.apple.webarchive` 及其旧名 → 拒绝。
   - 纯文本里有链接（`NSDataDetector`，含邮箱）或 `@名字`（前面不是字母数字或点）→ 拒绝。
   - 其他非文本类型（如 `org.chromium.source-url` 这类来源元数据）不算格式，不拒绝。这是对“RTF/HTML 等非纯文本类型”的落地解释：只列格式类型，不把所有非纯文本类型都算进去。
   - **风险（需实测）**：Chromium/Electron 复制或提供选区时常常同时放 `public.html`，哪怕内容只是纯文字。如果 Slack 也这样，A 和 B 在 Slack 里会**每次都被拒**。实测步骤里加了查看剪贴板类型的一步；若确认如此，改法是：有 HTML 时检查内容，只有含链接/提及/格式标签才拒绝（一处改动，`HandoffPolicy.isRich`）。
   - `@名字` 规则对含空格的 Slack 显示名只匹配第一个词，足够判定“有提及”。

## 仍待定

- README Setup 第 4 步文案（上面草稿）。
- 服务调用无法验证调用方身份（安全审查提出）：现在有 Slack 前台判断 + 不嵌套；更严的做法（每个调用方首次确认、限频）未做。
