# Be Nice 全流程 UX 检查（2026-10）

> 状态：**只看代码和已有测试报告**，没有做任何 GUI 操作、没有动鼠标、没有前台测试。“依据”一列：**源码** = 从代码读出、确定会发生；**报告** = 已在真实 Slack 里观察到（引用 `docs/research/` 的报告）；**推测** = 视觉或体验判断，要看界面确认。
> 基线：main `565ddae`（含 PR #18）。零权限模式按 PR #17 分支 `mfang0126/be-nice-no-ax-mode`（`fcb8178`，未合并）读。
> 范围：首次安装和权限引导、菜单栏菜单、触发（Rewrite 按钮 / ⌃⌥⌘Space）→ 改写窗口 → 选风格 → 替换 → 撤销、出错和超时、零权限模式、Slack 里的实际表现。Settings 窗口已单独审过（`docs/research/settings-ux-audit-2026-10.md`，分支 `mfang0126/be-nice-settings-ux-audit`），这里不重复，只在第 22 条列出剩下的项目。

## 结论先说

最影响使用的 5 个问题：

1. **按快捷键没反应，也不说为什么**（第 1 条）。没有辅助功能权限、输入框没有焦点、Slack 不在最前面、开了安全输入，这几种情况快捷键都静默失败。`WriteBack` 里其实写好了“Click into the Slack message box…”这类提示，但触发层提前 `return`，用户永远看不到。
2. **“Replaced / Undo” 胶囊不会自己消失，成功时也没有 Dismiss**（第 2 条）。它在 floating 层级之上，切到别的 App 也还浮在屏幕上，直到下一次改写；消息发出后上面还留着一个已经不能用的 Undo。
3. **真实 Slack 草稿很多会变成“只能复制”，而复制之后怎么办没有说明**（第 3 条）。emoji、@提及、链接、列表都会走 Copy rewrite；窗口只说“不能替换”，不说“关掉窗口后在输入框里 ⌘A ⌘V”；这时 ⌘↩ 什么都不做。
4. **首次使用没有引导**（第 4 条）。启动后只有一个菜单栏图标；菜单第一行是 “Accessibility: Not granted”，不解释为什么要、授权后怎么用；模型没配置要等第一次在 Slack 里触发失败才弹出 Settings；Copilot 还要求先装 `gh` 并在终端登录。
5. **零权限模式（PR #17）可能在 Slack 里完全用不了，能用时也和主流程承诺不一致**（第 5 条）。富内容规则看到 `public.html` 就拒绝，而 Slack（Chromium）复制纯文字时很可能也带 HTML；服务菜单 A 不给预览、直接用第 1 个风格替换；剪贴板 B 要按 4 次键；菜单文案只提到剪贴板，没提服务菜单。

GUI 确认清单共 **10 项，约 29 分钟**，拆成 6 个不超过 5 分钟的焦点窗口（见文末）。

## 全流程（源码读出）

| 步骤 | 用户看到的 | 源码 |
|---|---|---|
| 安装 | 右键打开（未公证）；README 第 4 步要求授权辅助功能 | `README.md:22-25` |
| 启动 | 没有窗口、没有 Dock 图标，只有菜单栏 `wand.and.stars` 图标 | `main.swift:21-23`、`MenuBarShell.swift:205-220` |
| 菜单 | 状态行（权限）、Request Accessibility Access…（只出现到点过一次）、Open Accessibility Settings…、Check Again、快捷键说明（灰）、Settings…、Undo Last Replace、Quit | `MenuBarShell.swift:130-174` |
| 入口 | 输入框有焦点时，输入框上方右侧出现紫色 “✎ Rewrite” 按钮；或按 ⌃⌥⌘Space | `TriggerController.swift:126-147`、`:373-403`、`:435-440` |
| 等待 | 输入框上方深色胶囊 “Rewriting…” + Cancel；模型超时 60 秒 | `OptimizerController.swift:39-42`、`ModelClient.swift:193` |
| 选择 | 全屏半透明遮罩 + 1120 宽面板：YOUR DRAFT、修改指令框、三张卡、底部提示和 Cancel / Replace with X | `RewriteWindowController.swift:308-333`、`:622-760` |
| 替换 | 窗口隐藏 → 激活 Slack → 写入 + 读回 → 胶囊 “Replaced” + Undo | `OptimizerController.swift:145-176` |
| 撤销 | 点胶囊 Undo 或菜单 Undo Last Replace → 胶囊 “Restored” | `OptimizerController.swift:180-198` |
| 零权限 A | 选中草稿 → Slack 的“服务”菜单 → Rewrite with Be Nice → 直接替换，⌘Z 撤销 | PR #17 `NoAXMode.swift:181-210`、`Support/Info.plist` |
| 零权限 B | ⌘A ⌘C → ⌃⌥⌘Space → 鼠标旁胶囊 “Copied — press ⌘V” → ⌘V；Undo 恢复原剪贴板 | PR #17 `NoAXMode.swift:216-245` |

## 问题清单

| # | 问题 | 在哪（文件:行） | 现象 | 为什么是问题 | 严重度 | 建议改法 | 依据 |
|---|---|---|---|---|---|---|---|
| 1 | 快捷键在多种情况下静默失败 | `TriggerController.swift:564-585`（无权限 / 安全输入 / 非 Slack 直接 `finishPending(nil)`）、`:663-672`（`target` 为 nil 时 `return`） | Slack 在前但光标不在输入框、没授权、开着密码框的安全输入、Slack 不在最前面时按 ⌃⌥⌘Space：什么都不出现 | 用户会以为 App 坏了或快捷键没注册。`WriteBack.swift:76-90` 已有对应的人话提示（“Click into the Slack message box and try again.”），只是到不了 | P1 | 快捷键路径拿不到 target 时，按原因在鼠标旁显示一次状态胶囊（复用 `RewriteStatusController` 和 `WriteBack` 的文案）；Rewrite 按钮路径不用改（按钮只在有 target 时出现）。PR #17 已把“没授权”这一种接到剪贴板模式 | 源码 |
| 2 | 成功胶囊不自动消失、没有 Dismiss，会浮在别的 App 上 | `StatusPill.swift:57-62`（成功 + 有 Undo 时只有 Undo 按钮）、`:24-25`（floating+1 层级，`hidesOnDeactivate = false`）；`OptimizerController.swift:169`、`:249-261`（没有定时隐藏） | 替换后 “✓ Replaced [Undo]” 一直贴在 Slack 输入框上方，盖住消息列表最后一行；切到浏览器它还在原位置；消息发出后 Undo 还在，点了被拒绝，报 “The draft changed. Rewrite it again.”（`WriteBack.swift:766`） | 一个关不掉的浮窗会挡内容，用户只能去点 Undo 或再改写一次才能让它走。发出后的 Undo 是失效操作 | P1 | 成功胶囊加 Dismiss（或 × ）；8–10 秒后自动隐藏（菜单的 Undo Last Replace 仍可用）；Slack 失去前台或输入框值变了就隐藏 | 源码；盖住最后一行见报告 `s3-slack-regression-2026-10-27.md:306`；浮在别的 App 上是推测 |
| 3 | 富内容只能复制，复制后的下一步没有说明 | `WriteBack.swift:81`、`:975-979`；`RewriteWindowController.swift:271`、`:413-415`、`:456-460`；`:482`（copy-only 时 ⌘↩ 被吞掉，不复制）；`README.md:16` | 草稿里有 emoji、@提及、链接、列表、格式就进 copy-only：底部写 “This draft has emoji, mentions… You can view, edit or copy this rewrite, but not replace.”；点 Copy rewrite 后只显示 “Copied.”，窗口不关；按 ⌘↩ 没反应 | Slack 消息里 emoji、提及、链接很常见，这条路径不是少数情况。用户拿到了改写但不知道要关窗口、回到输入框、⌘A ⌘V；提示 ⌘↩ 是主操作，在这里却失效 | P1 | copy-only 时：⌘↩ 执行 Copy；复制成功后关窗口、回到 Slack，胶囊提示 “Copied — select your draft and press ⌘V”；原因文案按实际命中的一类说（“has a mention”），不列全部 | 源码；命中频率是推测，D4/D5 见报告 |
| 4 | 首次使用没有引导，模型配置要等失败后才弹 | `main.swift:21-23`；`MenuBarShell.swift:194-203`（状态行只写权限）、`:176-180`（Request 项点一次后永久隐藏）；`OptimizerController.swift:48-51`（第一次触发才发现没配模型）；`README.md:25`、`:33` | 首次启动什么都不弹。用户要自己找到图标、读懂 “Accessibility: Not granted”、授权、再打开 Settings 选模型。没配模型时第一次点 Rewrite，胶囊报错并打开 Settings。Copilot 需要先 `brew install gh` 和 `gh auth login` | 菜单栏工具最常见的失败是“装了不知道怎么用”。现在的状态行回答的是“权限是什么状态”，没回答“下一步做什么”。`gh` 对非开发者门槛高 | P1 | 首次启动显示一个小的欢迎窗口（3 步：授权 → 选模型 → 在 Slack 里按 ⌃⌥⌘Space），每步有按钮和已完成标记；菜单状态行改成下一步（“Next: choose a model in Settings”）。要做的话先写进 PLAN | 源码；“不知道怎么用”是推测 |
| 5 | 零权限模式在 Slack 里可能每次都被拒，A 不给预览 | PR #17 `NoAXMode.swift:40-56`（`isRich`：有 `public.html` 就拒绝）；`:181-210`（A 直接返回第 1 个风格的结果）；`MenuBarShell.swift:196`、`:209`；`docs/design/no-ax-mode.md` “决定 3 风险” | Slack 复制或服务调用时如果带 `public.html`（Chromium 常见），A 和 B 都报 “This has links, mentions or formatting…”。A 能用时，选中的草稿直接被改写结果替换，没有三选一、没有确认；撤销靠 Slack 的 ⌘Z（未验证）。B 要 ⌘A ⌘C、⌃⌥⌘Space、⌘V 四次按键。菜单只说 “Clipboard mode”，服务菜单入口没人告诉用户 | 前一种情况下整个模式等于不存在。A 直接替换和 README 的“pick from three versions… confirm”不一致，替换错了能不能撤回还不知道 | P1（取决于实测） | 先跑 PR #17 用户测试第 7.5 步看剪贴板类型；如果确认有 HTML，`isRich` 改为检查 HTML 内容（有 `<a`、提及、格式标签才拒绝）。A 改写后先在鼠标旁显示结果和 Replace / Cancel，确认再写回（服务 55 秒内要返回，需评估）；菜单加一行 “Or select text → Slack ▸ Services ▸ Rewrite with Be Nice” | 源码；HTML 是否存在、⌘Z 是否有效是推测 |
| 6 | 错误信息是开发者用语，也没有重试按钮 | `ModelClient.swift:55-72`（“Network error: …”、“Model service returned HTTP 429”）；`RewriteOptions.swift:133-139`（“Rewrite response must contain only a valid JSON object.”）；`OptimizerController.swift:107`；`StatusPill.swift:57-62`（错误只有 Dismiss） | 断网、限流、模型输出格式不对时，胶囊直接显示这些原文 | 用户看不懂，也不知道是自己的问题还是服务的问题；“JSON”“HTTP 429”对普通用户没有意义。草稿没变，重试是安全的，但要用户自己再触发 | P2 | 映射成 3 类人话：连不上（“Can't reach the model. Check your connection.”）、太忙（429：“The model is busy. Try again in a minute.”）、答得不对（解析错：“The model's answer didn't come back right. Try again.”）；胶囊加 Retry | 源码 |
| 7 | Rewrite 按钮在输入框有焦点时一直出现，盖住最后一条消息 | `TriggerController.swift:616-641`（只要有焦点就显示，不看草稿是否为空）、`:137`（首选位置：输入框上方右侧）、`:378-385` | 空输入框也显示 “✎ Rewrite”；按钮和之后的状态胶囊都在输入框正上方，压住消息列表最后一行的下沿 | 常驻的紫色按钮会让用户觉得 Slack 被“贴了东西”；空草稿点了只得到 “The message box is empty.” | P2 | 草稿为空时不显示按钮（`TriggerAX.Snapshot` 现在不读值，要在快照里多读一次 AXValue）；按钮缩成只有图标的小圆钮，悬停再展开文字 | 源码；遮挡见报告 `s3-slack-regression-2026-10-27.md:306` |
| 8 | 改写窗口提示 “nothing is sent” 有歧义 | `RewriteWindowController.swift:272` | 底部提示 “⌘↩ replace · esc close · nothing is sent” | 草稿这时已经发给模型了。这句话的本意是“不会替你在 Slack 发消息”，但用户可能理解成“草稿没有离开本机”，和隐私说明（`README.md:36`）冲突 | P2 | 改为 “never sends the message for you”，或直接删掉这一段 | 源码；误解是推测 |
| 9 | 单独成段的 @提及会被当成纯文本替换掉 | `WriteBack.swift` `childrenAreRich`（只看多段 `AXStaticText`） | 一段里只有 `@Full Name` 时检测不到，替换后提及胶囊变成纯文本或消失；撤销后 Slack 重新识别 | 提及丢了用户不一定注意到，发出去对方收不到通知 | P2 | 报告已记为已知限制。可以在替换前对草稿原文再跑一次 `@` 规则（和 PR #17 `HandoffPolicy` 的提及正则同一条），命中就 copy-only | 报告 `s3-slack-regression-2026-10-27.md:171` |
| 10 | 零权限模式的服务菜单不好找 | PR #17 `Support/Info.plist` `NSServices`（无 `NSKeyEquivalent`） | 入口在 Slack ▸ Services 子菜单；Electron 的右键菜单通常没有“服务”；新注册的服务有时要注销重登或 `pbs -update` 才出现 | 用户不知道有这个入口，找到了也要走两级菜单；配快捷键要去系统设置 | P2 | 在菜单和首次引导里写清路径；提供一键打开“键盘快捷键 ▸ 服务”的菜单项 | 源码；Slack 里能否看到是推测 |
| 11 | 改写窗口强制浅色，遮罩点了不关 | `RewriteWindowController.swift:633`（`.aqua`）、`:626-628`（全屏遮罩） | 系统和 Slack 都是深色时，弹出一块大白面板；点遮罩空白处没有反应，只能 Esc 或 Cancel | 深色下刺眼；点外面关闭是常见预期 | P3 | 跟随系统外观（颜色已集中在 `Palette`，要补深色值）；点遮罩等于 Cancel | 源码；刺眼是推测 |
| 12 | 等待只有转圈，最长 60 秒 | `ModelClient.swift:193`；`OptimizerController.swift:39-42` | 慢模型时胶囊 “Rewriting…” 转圈到 60 秒才报超时 | 不知道还要等多久；10 秒以上没变化会以为卡住 | P3 | 10 秒后文案改为 “Still rewriting… (Cancel to stop)” | 源码；等待时长是推测（报告里 Test 为 1.2 s） |
| 13 | 授权后菜单仍显示权限相关项 | `MenuBarShell.swift:144-152`、`:176-180` | 授权后 “Open Accessibility Settings…” 和 “Check Again” 一直在菜单里 | 菜单 8 项里 3 项和权限有关，日常用不到；真正要用的入口（怎么触发）只是一行灰字 | P3 | 授权后隐藏这两项，放进 “Troubleshooting” 子菜单 | 源码 |
| 14 | 快捷键注册失败时显示原始错误码，快捷键也不能改 | `MenuBarShell.swift:188`；`TriggerController.swift:435-440` | “Shortcut unavailable (-9878); use the floating dot” | 错误码没意义；“floating dot” 和界面上的 “✎ Rewrite” 按钮叫法不一致 | P3 | 改为 “⌃⌥⌘Space is used by another app; use the Rewrite button above Slack's message box”；改快捷键先写进 PLAN | 源码 |
| 15 | 模型会重复或改动草稿里的标签 | 提示词在 `ModelClient.swift`（`rewriteOptions`） | 主回归用例 1：Polite 卡把 `[be-nice test]` 写了两次 | 改写质量问题，用户要手动删 | P3 | 提示词里加“保留开头的标签只出现一次”，或替换前检查标签次数 | 报告 `s3-slack-regression-2026-10-27.md:301` |
| 16 | 线程输入框的 Rewrite 按钮在 Slack 慢的时候闪烁 | `TriggerController.swift:204-205`（快照 0.6 s 时限）、`:73-75` | 祖先遍历没在时限内走到 AXWebArea 时按钮隐藏，下一轮又出现 | 视觉不稳定；失败方向安全（不显示，不误写） | P3 | 报告已记为已知限制；缓存上一次成功的祖先深度 | 报告 `s3-slack-regression-2026-10-27.md:170` |
| 17 | 不能开机自启 | 仓库没有 `SMAppService` / 登录项 | 重启电脑后 App 不在，按快捷键没反应（叠加第 1 条） | 菜单栏工具一般默认或可选开机启动 | P3（范围） | 菜单加 “Open at Login”（`SMAppService.mainApp`）；先写进 PLAN | 源码 |
| 18 | 零权限 B 的成功和恢复都叫 “Restored”/“Copied”，和一键模式共用胶囊但位置不同 | PR #17 `NoAXMode.swift:192`、`:222`、`:242`（`mouseRect`） | 一键模式的胶囊贴输入框，零权限模式贴鼠标；鼠标在屏幕另一边时提示远离用户看的地方 | 位置跳来跳去；用户刚 ⌘C 时视线在输入框，不在鼠标 | P3 | 可接受（没有权限拿不到输入框位置）；鼠标离前台窗口太远时改放到前台窗口中下方（`CGWindowList` 不需要辅助功能） | 源码；视线是推测 |
| 19 | Undo 只有一次，且只针对最近一次替换 | `OptimizerController.swift:7-10`、`:180-198` | 连续替换两次后只能撤回第二次 | 符合“撤销最近一次”的说法，但菜单项没写清是哪一次 | P3 | 菜单项保持；README 已说明，暂不改 | 源码 |
| 20 | 选风格菜单里 “你的三个风格” 和其他预设没有说明区别 | `RewriteWindowController.swift:508-530` | 卡片上的风格名可以点开换风格；菜单分两组 | 用户可能以为在这里换会改默认（tooltip 有说明 `:178`，但要悬停才看到） | P3 | 菜单顶部加一行灰字 “For this rewrite only” | 源码 |
| 21 | 中文界面不存在 | 所有字符串写在代码里 | 全英文 | 主要用户写中文草稿；范围问题 | P3（范围） | 不在本轮；要做先写进 PLAN | 源码 |
| 22 | Settings 审计剩下的项目 | `settings-ux-audit-2026-10.md` 第 9、13–18 条 | Undo/Redo 菜单（#9，要改 `MenuBarShell.swift`，等 PR #17 合并后做）；显式 Save 模式（#13）；P3 文案和布局（#14–#18） | 见原审计 | P2（#9）/ P3 | 见原审计 | 源码 |

## 需要真实界面确认

每项写清截哪个画面、预计时间。全部只用合成草稿（`[be-nice test] …`），不发送消息。标 “前台” 的要 Slack 在最前面，按 AGENTS.md 集中进焦点窗口；标 “后台” 的可随时做。

| # | 对应问题 | 操作 | 截哪个画面 | 前台/后台 | 预计 |
|---|---|---|---|---|---|
| G1 | 4、13 | 点菜单栏图标打开菜单（未授权的开发版和已授权的安装版各一次） | 菜单全貌两张 | 前台（要点菜单栏） | 2 分钟 |
| G2 | 1 | Slack 在前，点一下消息列表让输入框失焦，按 ⌃⌥⌘Space | 按键后 2 秒的 Slack 全窗口（预期：什么都没有） | 前台 | 2 分钟 |
| G3 | 2 | 替换一条合成草稿，然后切到另一个 App（如访达），再切回 Slack 发送前清空输入框 | ① 替换后输入框上方 ② 切到访达后的整屏 ③ 清空输入框后的胶囊 | 前台 | 4 分钟 |
| G4 | 3 | 合成草稿里加一个 emoji（`:smile:` 转换后的），点 Rewrite，按 ⌘↩，再点 Copy rewrite | ① 改写窗口底部文案 ② 按 ⌘↩ 后（预期不变）③ 点复制后 | 前台 | 3 分钟 |
| G5 | 6 | 粘贴一条 8001 字的合成草稿后点 Rewrite（本地就拒绝，不发模型请求） | 错误胶囊 | 前台 | 2 分钟 |
| G6 | 7 | 清空输入框，只点进输入框 | 空输入框上方的 Rewrite 按钮和最后一条消息 | 前台 | 1 分钟 |
| G7 | 11 | 用户把系统外观切到深色后触发一次改写 | 改写窗口全屏（要用户自己切外观，不由 agent 改系统设置） | 前台 | 3 分钟 |
| G8 | 5、10、18 | 和 PR #17 用户测试同一次做：第 7.5 步看 Slack 复制后的剪贴板类型；Slack ▸ Services 菜单；输入框右键菜单；B 流程一次 | ① `osascript -e 'clipboard info'` 输出（后台）② Services 子菜单 ③ 右键菜单 ④ B 的鼠标旁胶囊 | 前台（③④）+ 后台（①） | 8 分钟 |
| G9 | 22 | PR #18 的 Settings 布局目视检查（已交给用户） | Settings 全窗口：Custom、Copilot 各一张 | 前台 | 3 分钟 |
| G10 | 8、20 | 改写窗口出来后，悬停卡片风格名，点开风格菜单 | 底部提示行、风格菜单 | 前台 | 1 分钟 |

合计约 **29 分钟**。按每个焦点窗口不超过 5 分钟拆：① G2+G6+G10（4 分钟）② G3（4 分钟）③ G4（3 分钟）+ G5 留到下一窗口 ④ G5+G1（4 分钟）⑤ G7（3 分钟，要用户先切外观）⑥ G8 前台部分（约 5 分钟，并入 PR #17 测试）。G9 已在交给用户的清单里。

做不到的：没配模型的首次体验（第 4 条后半）要清空现有模型配置，规则禁止覆盖 App 里的配置，只能在一个全新的 macOS 用户里做，没有列进清单。
