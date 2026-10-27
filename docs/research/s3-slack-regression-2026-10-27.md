# S3 Slack 回归 + 全新安装实测（2026-10-27）

> 环境：Slack 桌面版，测试工作区 `mingfang.tech`（只有用户一人）；开发版 `~/Applications/be-nice Development.app`，provider Copilot `gpt-4o-mini`。
> 用户 20:44 授权前台测试约 60 分钟。全部草稿为带 `[be-nice test]` 的合成文本；除下面一条父消息外未发送消息。
> 操作：LCU 点击（Rewrite、Replace、Undo 胶囊）；读回：独立读取 Slack 输入框 AX 值（不经 be-nice）。
> 中断：20:51–20:57 屏幕自动锁定（`CGSSessionScreenIsLocked=true`，LCU 报 `cgWindowNotFound`），解锁后继续；除 T2（线程入口不出现）外用例都已跑。
> 唯一发送的消息：20:59 在 #all-mingfangtech 发 `[be-nice test] thread parent`（用户授权，用作线程父消息）。be-nice 本身未发送任何消息。

## 1. 全新安装路径（PLAN 第 6 项）— 通过

| 步骤 | 预期 | 实测 |
|---|---|---|
| 退出 App，`defaults delete com.benice.menubar.development`，启动监控，`open -g` | 无配置 | `defaults export` 为空 `{}` |
| #all-mingfangtech 合成草稿上点 Rewrite | 只提示 + 打开设置，不调 `gh`、不联网 | 只打开 “Be Nice Settings”，状态行 “Choose where your drafts are sent. Nothing is sent until you Save.”；Copilot 预选、模型下拉禁用、“Click Test to check your GitHub login…”。监控 20:47:40–20:47:57：be-nice 子进程 `gh` 0 次，nettop 0 行 |
| 点 Test（第 1 次） | 才查登录 | 20:48:07 出现 be-nice 子进程 `gh auth token --hostname github.com`（首个 gh）；状态 “Using your GitHub login.”，模型 GPT-4o mini。按代码设计第 1 次 Test 只加载模型列表，不发改写请求 |
| 点 Test（第 2 次） | 一次成功 + 耗时 | “Worked in 1.2 s.” |
| Save → 关设置 → 再点 Rewrite | 三张卡 | “Saved.”；三张卡（Polite / Shorter / Friendly），Cancel 后输入框原文不变 |
| 恢复 | 与备份一致 | 退出 App → `defaults import` 备份 → `diff <(plutil -p 备份) <(defaults export … - \| plutil -p -)` 为空 → `open -g` 重启 |

观察：第 1 次点 Test 后状态行仍是 “Choose where…”，没有“再点一次 Test 发测试请求”的提示，用户可能以为已测过。

## 2. 私聊（DM 自己，`Ming Fang (DM) - mingfang.tech - Slack`）

DM 输入框原有一条未发送草稿（无测试标记，来源未证实）。按协调者指示：先记下原文，测完恢复并读回。

| # | 输入 | 入口 | 卡片 | 替换后读回 | Undo 读回 | 结果 |
|---|---|---|---|---|---|---|
| D1 | `[be-nice test] 麻烦你明天之前看一下构建日志，有问题告诉我。`（粘贴） | Replace with Polite（直接替换） | **三张全是英文**，例：“Could you please take a look at the build log before tomorrow and let me know if there are any issues?” | `Could you please take a look at the build log before tomorrow and let me know if there are any issues?` | 与原文逐字一致 | **失败**：违反 PLAN“保持原文语言、不主动翻译”（PLAN 第 10、63 行）。写回/撤销本身通过 |
| D1b | `[be-nice test] 这个需求我们下周再讨论吧，今天先把bug修了。`（粘贴） | Replace with Polite | 中文；Polite “我们下周再讨论这个需求吗？今天先修复这个bug吧。”（陈述变问句）；Shorter “下周再讨论需求，今天先修bug。” | 与 Polite 卡一致 | 逐字一致 | 写回/撤销 通过；保真有偏差（语气改成问句） |
| D2 | `[be-nice test] 我晚点再看这个问题，先别合并。`（LCU `typeText` 逐字输入，**不是真 IME**） | Replace with Polite | 中文；Polite “请稍等，我稍后会再考虑这个问题，请不要合并。” | 与 Polite 卡一致 | 逐字一致 | 通过（保真小偏差：“看”→“考虑”，加“请稍等”） |
| D3 | （已修，见第 6 节重跑）17 行英文周报，含 `1.`–`13.` 编号行和空行（粘贴） | Replace with Polite（直接替换） | 三张卡均保留 13 条 | 15 行纯文本 “1. There were…” | AX 字符串一致，**但截图显示有序列表没了**，变成 “1.The …” 段落（数字后无空格） | **失败**：列表被当纯文本直接替换；撤销没有恢复列表格式 |
| D4 | （已修，见第 6 节重跑）`[be-nice test] can you review the parser fix today @Ming Fang please`（`@Ming` + Tab 生成真提及胶囊） | **Replace with Polite（未识别为富内容）** | 第 1 次 “Would you be able to review the parser fix today, please, @Ming Fang?”；第 2 次 Polite 写成 “…please, Ming Fang?”（@ 都没了） | 截图：提及胶囊消失，变纯文本 | AX 一致，截图提及胶囊恢复 | **失败**：提及未被检测，替换丢掉提及；撤销能恢复 |
| D5 | `[be-nice test] the failing job is build 123, can you check it`（HTML 粘贴，`build 123` 是指向 example.com 的链接） | **Copy rewrite** | 状态 “This draft has emoji, mentions or links that a replace would drop…” | Cancel 后输入框不变 | — | 通过（链接被识别，只给复制） |

D3 说明：粘贴后 Slack 把 `1. ` 行自动转成有序列表（AX 值是 `1.The …`）。be-nice 判为纯文本、给直接替换。撤销写回的是 AX 字符串 `1.The …`，所以 AX 读回“一致”，但界面上列表变成普通段落、数字后没有空格。**AX 字符串相等不能证明撤销精确**，富结构要配截图。

D4 说明：Slack 提及胶囊在 AX 值里就是纯文本 `@Ming Fang`，现有富内容检测没认出来。撤销后胶囊重新出现（推测 Slack 对 `@全名` 自动识别），不保证对重名或非成员成立。

DM 原草稿 `hi, the numbers in the report look off, can you fix them by tomorrow?` 已用粘贴恢复，AX 读回逐字一致。

所有用例：三张卡都把 `[be-nice test]` 标记删掉了（全新安装那次也一样）。点 Replace 时 LCU 报 `AXError.failure`（窗口在点击中关闭），替换本身成功。

D1 三张卡原文（输入 `[be-nice test] 麻烦你明天之前看一下构建日志，有问题告诉我。`）：
- Polite：`Could you please take a look at the build log before tomorrow and let me know if there are any issues?`
- Shorter：`Please check the build log by tomorrow and inform me of any issues.`
- Friendly：`Hey! When you get a chance, could you look at the build log before tomorrow? Let me know if anything seems off!`

## 3. 频道（#all-mingfangtech 主输入框）

| # | 输入 | 入口 | Polite 卡 | 替换后读回 | Undo 读回 | 结果 |
|---|---|---|---|---|---|---|
| C1 | `[be-nice test] Can you check the build logs before tomorrow?` | Replace with Polite | “Would you be able to check the build logs before tomorrow, please?” | 一致 | 逐字一致 | 通过 |
| C2 | `[be-nice test] 明天的会议改到下午三点，大家记得更新日历。` | Replace with Polite | “请注意，明天的会议已改为下午三点，希望大家能及时更新日历。” | 一致 | 逐字一致 | 通过 |

## 4. 线程回复输入框

| # | 输入 | 结果 |
|---|---|---|
| T1 | （已修，见第 6 节重跑）`[be-nice test] Thanks, I will look at it after lunch.`（粘贴进 “Reply to thread in all-mingfangtech”） | **失败：Rewrite 按钮不出现**。线程输入框有焦点、有文字（截图确认），连续两次重新点输入框后 be-nice 无任何窗口（LCU `timeoutReached`）；同时间点频道主输入框能出按钮。T2（中文）因入口不出现未跑。全局快捷键 LCU 发不了，未测 |

原因未查（本任务不改代码）。线索：`TriggerController.capture` 的 `ancestorRoles` 深度上限 16、`composerBox` 只看 4 层，以及线程面板在 AX 树里的位置，值得先用 `SlackDiagnostic` 读一次线程输入框的祖先链。

## 5. 清理

- DM 原草稿已恢复并读回一致；频道输入框为空（原合成草稿被父消息用掉）；线程输入框已清空。
- `~/Applications/.be-nice-install.*`（17 个，各含 `previous.app`）在确认 App 运行、`debug-status.py` = 0 后删除。
- 开发版 UserDefaults 与备份 `diff` 为空（测试结束再查一次）。

## 修复建议（本任务不改代码）

1. 提示词要求“保持草稿语言”，并校验输出语言与原文一致（D1）。
2. 方括号标签类前缀（如 `[be-nice test]`、`[WIP]`）被删除：提示词要求保留原有标签/前缀。
3. 有序/无序列表、提及胶囊应视为富内容（走 Copy rewrite）：AX 值里看不出，需要读子元素结构（D3、D4）。
4. 撤销验证不能只比 AX 字符串（D3）；结构化内容撤销前就应禁用直接替换。
5. 线程回复输入框入口不出现（T1）：先做只读诊断看祖先链，再定修法。
6. 设置页第 1 次 Test 只加载模型时，状态行应提示“Loaded. Click Test again to send a test request.”，或直接接着发测试请求。

## 6. 修复 A：只读诊断 + 重跑（21:10–21:16，分支 `mfang0126/fix-rich-thread`，基于 main 365d23c）

### 6.1 只读诊断（未改代码时）

工具：开发版 `slack-diagnostic.py`（祖先链）+ scratchpad 里的只读 AX 转储（只读 role/subrole/roleDescription，不写）。全部在 #all-mingfangtech 和它的线程里，合成草稿。

**祖先链（AXParent 逐层，第 n 层 = 第 n 个父节点）**

| 输入框 | 第 1–15 层 | AXWebArea 在第几层 | 之后 | AXWindow |
|---|---|---|---|---|
| 频道主输入框 | 全是 AXGroup（第 5、8 层 subrole `AXApplicationGroup`，第 9、12 层 subrole `AXTabPanel`） | **16** | AXScrollArea + 6 层 AXGroup | 24（subrole `AXStandardWindow`） |
| 线程回复输入框 | AXGroup（第 7 层角色不在诊断白名单内，记为 unknown），第 1–17 层无 AXWebArea | **18** | AXScrollArea + AXGroup… | 未到（诊断 24 层上限截断） |

**线程入口不出现的原因**：`TriggerController` 的祖先遍历上限 `maxAncestorDepth = 16`，遇到 AXWebArea 才算网页内容。线程输入框的 AXWebArea 在第 18 层，16 层内找不到 → `hide(.outsideWebContent)`。频道输入框刚好在第 16 层，处在上限边缘。原注释“Slack composer sits 10 levels below AXWebArea”已过时。

**输入框子树（AXTextArea 下）**

| 草稿 | 子树 |
|---|---|
| 空 | `AXGroup`（subrole `AXEmptyGroup`） |
| 提及：`[be-nice test] can you review the parser fix today @Ming Fang please`（`@Ming` + Tab，截图确认是胶囊） | `AXGroup` → 3 个 `AXStaticText`：正文、`@Ming Fang`、` please`。胶囊没有单独角色或 subrole（DOMClassList 为空）；AXAttributedStringForRange 里胶囊一段多一个 `AXBackgroundColor` |
| 有序列表：粘贴 `plan for today` + 三行 `1. ` 开头（截图确认是 Slack 列表） | `AXGroup`(正文) / `AXGroup`(`AXEmptyGroup`) / **`AXList`（subrole `AXContentList`）** → 每项 `AXGroup` → [`AXGroup`(`1`、`.` 两个 AXStaticText), `AXStaticText`] / `AXGroup`(`AXEmptyGroup`)。AXValue 为 `1.fix the parser`（数字后无空格），AXAttributedStringForRange 报错 -25212 |

**富内容检测漏判的原因**：`hasRichContent` 只认子节点角色 AXImage/AXLink/AXButton。列表是 AXList，提及只是同一段里多出一段 AXStaticText，都不在名单里。

### 6.2 修法（最小改动，不放宽任何安全检查）

- `WriteBackPolicy.childrenAreRich`：子节点里有 AXImage/AXLink/AXButton/**AXList**，或同一节点下 **多于一个 AXStaticText**（提及胶囊、行内格式把段落切成多段）→ 富内容，只给 Copy rewrite。`hasRichContent` 的遍历范围不变（深度 4、300 节点）。
- `TriggerPolicy.maxAncestorDepth` 16 → 24（仍要求祖先里有 AXWebArea；遍历到 AXWebArea 就停；快照总时限 0.6 s 不变）。
- 撤销（D3）：富内容在预览和写入前都会被 `recheck` 拒绝（`.richContent`），根本不产生替换，也就没有“声称精确恢复”的撤销。单测 30 已覆盖“预览后才变富 → apply 拒绝且不写”。
- 新单测：WriteBackTests 第 30 组加 7 条 `childrenAreRich`（提及、列表、emoji、链接为富；单段、纯段落、空为纯）；TriggerTests 加频道（16 层）/线程（18 层）链按上限截断后应显示。去掉修复（上限改回 16、删 AXList 与多段规则）后这 3 条断言失败，已验证。`run-tests.sh` ALL PASS。

### 6.3 重跑（重装开发版，debug-status = 0）

| # | 位置 | 输入 | 入口 / 结果 | 读回 | 撤销读回 | 结论 |
|---|---|---|---|---|---|---|
| D3' | 频道 | `[be-nice test] plan for today` + `1. fix the parser` / `2. update the docs` / `3. ping the team`（粘贴，截图确认变成 Slack 有序列表） | **Copy rewrite**，状态 “This draft has emoji, mentions or links that a replace would drop…” | 输入框未改 | — | 通过 |
| D4' | 频道 | `[be-nice test] can you review the parser fix today @Ming Fang please`（截图确认胶囊） | **Copy rewrite**，同上状态 | 输入框未改 | — | 通过 |
| C1' | 频道 | `[be-nice test] Can you check the build logs before tomorrow?` | Replace with Polite | `Could you please check the build logs before tomorrow?`（与卡片一致；截图确认在主输入框） | 原文逐字一致 | 通过（纯文本仍可直接替换） |
| T1' | 线程 | `[be-nice test] Thanks, I will look at it after lunch.` | **Rewrite 按钮出现**；Replace with Polite | `Thank you very much; I will review it after lunch.`，截图确认写进线程输入框、频道输入框为空 | 原文逐字一致 | 通过 |
| T2 | 线程 | `[be-nice test] 明天的会议改到下午三点，大家记得更新日历。` | Replace with Polite（三张卡都是中文） | `请注意，明天的会议时间已更改为下午三点，请大家更新日历。` | 原文逐字一致 | 通过 |

观察：
- 状态文案原来只说 “emoji, mentions or links”；已在 6.4 改为包含列表和格式。
- 卡片仍删掉 `[be-nice test]` 前缀（第 2 节第 5 条，不在本修复范围）。
- 清理：频道、线程输入框已清空（AX 读回为空）；DM 草稿未碰（侧栏 “Drafts & sent 1” 不变）；`~/Applications/.be-nice-install.*` 在 debug-status = 0 后删除。未发送任何消息。

### 6.4 第二轮：普通多行草稿仍可直接替换（21:18–21:25，协调者 review 追加）

疑问：“同一节点下多于一个 AXStaticText = 富内容”会不会把普通多行草稿也拦掉。实测（频道主输入框，修复后的安装版）：

| # | 草稿 | AX 子树（AXTextArea 下） | 入口 | 替换前 AXValue | 撤销后 AXValue | 结论 |
|---|---|---|---|---|---|---|
| a | 三段，段间空行（粘贴 `…build\n\nsecond…\n\nthird…`） | AXGroup[1 个 AXStaticText] / AXGroup(`AXEmptyGroup`) / AXGroup[1] / AXGroup(`AXEmptyGroup`) / AXGroup[1] | **Replace with Polite** | `[be-nice test] first paragraph about the build\nsecond paragraph about the docs\nthird paragraph about the release` | 逐字一致；截图空行恢复 | 通过（新文案版本上重跑一次，同样通过） |
| b | 三行，Shift+Return 换行（逐字输入） | 3 个 AXGroup，各 1 个 AXStaticText（Slack 编辑器把 Shift+Return 也做成独立段落，不是段内软换行） | **Replace with Polite** | `[be-nice test] line one about the build\nline two about the docs\nline three about the release` | 逐字一致 | 通过 |
| c1 | 加粗：`please check **the build** today`（⌘B） | AXGroup → AXStaticText / AXGroup(subrole `AXStrongStyleGroup`)[AXStaticText] / AXStaticText | **Copy rewrite** | — | — | 通过（富） |
| c2 | 行内代码：``run `make test` before merging``（反引号自动转换） | AXGroup → AXStaticText / AXGroup(subrole `AXCodeStyleGroup`)[AXStaticText] / AXStaticText | **Copy rewrite** | — | — | 通过（富） |

结论：Slack 每段都是一个 AXGroup、里面只有一个 AXStaticText，换行和空行都不会把一段切成多段文字，所以普通多行草稿不会被拦。规则**无需收窄**，D3'/D4'/C1'/线程用例无需重跑。加粗、行内代码同样会被识别为富内容（同一段里出现多段文字）。

注：Slack 的 AXValue 不含空段落（三段带空行的草稿读出来只有单个 `\n`），所以读回对比用的是替换前后的 AXValue，加截图确认空行。**更正（7.5）**：这只对“文字段后紧跟的第一个空段”成立，第二个及以后的空段会读成 `\n`。

状态文案改为 “This draft has emoji, mentions, links, lists or formatting that a replace would drop.”（`WriteBack.swift:81`），重装后在 c2 上看到新文案。`run-tests.sh` ALL PASS。清理：频道、线程输入框为空；DM 未碰；安装备份已删；未发送消息。

### 6.5 第三轮：段首/段尾/整段格式（21:23–21:28，PR #10 review 追加）

review 指出：6.4 的加粗/代码之所以被拦，是因为格式在段中间、把段切成两段 AXStaticText；格式在段首、段尾或整段时只有 0–1 个直接 AXStaticText，会被当成纯文本。

**实测子树（修复前读出，只读 AX 转储）**，频道主输入框，草稿用 Slack 标记 + ⇧⌘F 应用格式，截图确认：

| # | 草稿 | AXTextArea 下 | 入口（修复后安装版） |
|---|---|---|---|
| e1 | 段首加粗 `*[be-nice test] urgent* please check the build today` | AXGroup → AXGroup(`AXStrongStyleGroup`)[AXStaticText] / AXStaticText | **Copy rewrite** |
| e2 | 段尾加粗 `[be-nice test] please check the build *before lunch today*` | AXGroup → AXStaticText / AXGroup(`AXStrongStyleGroup`)[AXStaticText] | **Copy rewrite** |
| e3 | 整段加粗 `*[be-nice test] please check the build today*` | AXGroup → AXGroup(`AXStrongStyleGroup`)[AXStaticText] | **Copy rewrite** |
| e4 | 整段行内代码 `` `[be-nice test] make test` `` | AXGroup → AXGroup(`AXCodeStyleGroup`)[AXStaticText] | **Copy rewrite** |

review 的推断成立：e1–e4 每个节点下最多一个直接 AXStaticText，旧规则会判为纯文本并允许替换。

**修法**：`childrenAreRich(roles, subroles:)` 多看子节点 subrole，任何以 `StyleGroup` 结尾的（`AXStrongStyleGroup`、`AXCodeStyleGroup` 等）即富内容；`hasRichContent` 顺带读 AXSubrole，其余不变。纯段落的 subrole 只有 `AXEmptyGroup`，不受影响。单测：WriteBackTests 第 30 组加“段首加粗”“整段代码”两条，去掉 subrole 规则后两条失败（已验证）；TriggerTests 加“AXWebArea 在第 25 层（超出 24 层上限）→ hide(.outsideWebContent)”。`run-tests.sh` ALL PASS。

**纯文本复测（同一安装版，debug-status = 0）**

| # | 位置 | 草稿 | 入口 | 替换后读回 | 撤销后 AXValue | 结论 |
|---|---|---|---|---|---|---|
| f1 | 频道 | 三段带空行（`setValue`，子树：段 / 2×`AXEmptyGroup` / 段 / 2×`AXEmptyGroup` / 段；**7.5 注**：只有写入 `\n\n` 时才是 2 个空段，用户手打空行和写单 `\n` 都是 1 个，所以这里写的应是 `\n\n`） | Replace with Polite | 与 Polite 卡一致 | 逐字一致，子树同替换前 | 通过 |
| f2 | 频道 | Shift+Return 三行（逐字输入，截图无空行） | Replace with Polite | `Could you please provide details on the build, the documentation, and the release?` | 逐字一致 | 通过（见下方已知问题） |
| f3 | 线程 | `[be-nice test] Thanks, I will look at it after lunch.` | Rewrite 出现；Replace with Polite | `Thank you for your patience; I will review it after lunch.`（写进线程框，频道框为空） | 逐字一致 | 通过 |

**新发现（未修，不在本修复范围）**：f2 撤销后 AXValue 一致，但截图里三行之间多了空行，子树变成 段 / `AXEmptyGroup` / 段 / `AXEmptyGroup` / 段。原因推断：撤销用 AXValue 写回 `\n`，Slack 把每个 `\n` 变成新段落，原来的 Shift+Return 行距没法还原。6.4 b 当时只比了 AXValue，没截图。属于 D3 同类问题（撤销验证只比 AX 字符串）。

**已知限制（记录，不改）**
- 慢的 Slack 可能让线程输入框的 Rewrite 按钮闪烁：祖先遍历在 0.6 s 快照时限内没走到第 18 层 AXWebArea 时会隐藏按钮。失败方向是“不显示”，不会误写。
- 单独成段的提及胶囊（一段里只有 `@Full Name`）只有一个 AXStaticText，没有独立角色或 subrole，会被当成纯文本；替换会丢胶囊，撤销后是纯文本 `@Full Name`，Slack 会重新识别成提及（见 D4）。

清理：频道、线程输入框已清空（AX 读回为空）；DM 未碰（侧栏 “Drafts & sent 1” 不变）；`~/Applications/.be-nice-install.*` 在 debug-status = 0 后删除；未发送任何消息。

## 7. 修复 C：Shift+Return 多行草稿（21:32–21:40，分支 `mfang0126/be-nice-fix-linebreaks`，基于 main 0afe95f）

### 7.1 原因

Slack 走整篇写入：替换是 `setValue(建议)`，撤销是 `setValue(原 AXValue)`（`WriteBack.swift` apply/undo），不粘贴、不发按键。
- AXValue 用单个 `\n` 连接有字的段落，空段落不出现。（**7.5 更正**：只有文字段后的第一个空段不出现，其余空段各读成一个 `\n`。）
- Slack 把写入的每个 `\n` 变成“新段落 + 一个空段落”，也就是一行空行。（**7.5 更正**：`\n` 连写 k 个得到 k 个空段。）7.3 b 用 setValue 写单 `\n` 的三段，截图有空行，这一点已再次确认。

所以 setValue 只能还原“段 (空段 段)*”这种结构（**7.5**：修复 C 第二轮改为按段落结构写 U+2028，所有纯段落结构都能还原，这条规则已删除）：
- Shift+Return 的行是相邻段落，中间没有空段（6.4 b），无法还原，撤销后会多出空行（6.5 f2）。
- 双空行、段首空行、段尾空行也无法还原。
- 6.4 a 的单空行分段能还原，只是凑巧和 setValue 的结果一致。

### 7.2 修法（复制降级，不放宽任何安全检查，不碰剪贴板，不发按键）

- 新增 `WriteBackPolicy.paragraphsRestorable(roles, subroles:)`，只看输入框的直接子节点（`hasRichContent` 遍历的第 0 层）。规则：全部是 AXGroup，并且按“段、`AXEmptyGroup`、段……”交替，首尾都是段。不符合就判为 `.richContent`，只给 Copy rewrite。预览前、替换前都会检查。subrole 数组改成和 role 一一对应（没有 subrole 记 `""`）。读不到的树按可还原处理，与原规则一致。
- 状态文案改为 “This draft has emoji, mentions, links, lists, formatting or line breaks that a replace would change.”
- PLAN 第 22 行允许“结构无法保证时只给预览/复制”。单行和单空行分段仍然直接替换。
- 单测：WriteBackTests 第 30 组新加 8 条。旧行为下（scratch worktree 换回 HEAD 源码，规则恒为 true）Shift+Return、双空行、段首空行、段尾空行 4 条失败；另 4 条是回归保护，新旧代码都通过。scratch worktree 已删除。`run-tests.sh` ALL PASS。

### 7.3 实测（重装开发版，debug-status = 0，频道 #all-mingfangtech，截图 + AX 读回）

| # | 位置 | 草稿 | 入口 | 替换后 | 撤销后 | 结论 |
|---|---|---|---|---|---|---|
| a | 频道 | Shift+Return 三行（逐字输入，截图无空行） | **Copy rewrite**，显示新文案 | — | — | 通过（草稿未改） |
| b | 频道 | 三段单空行（setValue 单 `\n`，截图有空行） | Replace with Polite。Polite 卡手动改成三行再替换 | 截图：三段，每段之间一行空行，和原结构一致；AXValue 等于卡片内容 | 截图：三段单空行，与替换前一致；AXValue 逐字一致 | 通过 |
| b′ | 频道 | 同上（b 的结果再改写一次，模型给了单行） | Replace with Polite | 单行 | 恢复三段单空行（截图） | 通过 |
| c | 频道 | 单行 `[be-nice test] can you check the build before lunch` | Replace with Polite | `[be-nice test] Could you please check the build before lunch?` | 逐字一致，截图单行 | 通过 |
| d | 线程 | 单行 `[be-nice test] Thanks, I will look at it after lunch.` | Replace with Polite | `[be-nice test] Thank you. I will review it after lunch.`（频道框为空） | 逐字一致，截图单行 | 通过 |
| d2 | 线程 | Shift+Return 两行 | **Copy rewrite**，显示新文案 | — | — | 通过 |

Undo 走状态胶囊：先点 Slack 的 Messages 标签让输入框失焦，再绑定胶囊点 Undo。

### 7.4 U+2028 探测（只做证据，不改代码）

在频道输入框用 LCU setValue 写入 `[be-nice test] u2028 line one` + U+2028 + `line two` + U+2028 + `line three`，未发送。
- **截图**：三行紧挨着，没有空行，和 Shift+Return 看起来一样。
- **结构**：be-nice 对这条草稿给 Copy rewrite，说明子树是相邻段落、中间没有空段，和 Shift+Return 相同。
- **AXValue**：读回 `…line one\nline two\nline three`。状态字符串里查不到 U+2028，换行是普通 `\n`。也就是说，Slack 编辑器在写入时已经把 U+2028 转成段落分隔，输入框里不再留这个字符。
- **会发出去的内容**：从输入框判断，它的模型和 Shift+Return 草稿完全一样（相邻段落），所以发送的应是普通换行，不含 U+2028。这是推断，没有真的发送。

**结论：以后的替换和撤销可以保留软换行。** 写入前把字符串按原结构编码：相邻段落之间写 U+2028，单空行写 `\n`。Slack 写入后的结构和原草稿一致，AXValue 仍然读回 `\n`，现有的读回比对不用改。撤销要按捕获时的段落结构编码原文。替换要决定建议里的单个 `\n` 是软换行还是空行，建议沿用原草稿的风格。要做到这些，需要在 capture 时记下段落结构，并在 Slack 写入层做编码，属于新功能，按 AGENTS 先写进 PLAN。还需要实测：双空行（`\n` 加 U+2028？）、段首/段尾空行、线程输入框、发出后的消息（需用户授权才能发送）。

清理：频道、线程输入框已清空（AX 读回为空）；DM 未碰（侧栏 “Drafts & sent 1” 不变）；`~/Applications/.be-nice-install.*` 在 debug-status = 0 后删除；未发送任何消息。GUI 使用时段 21:36–21:39。

### 7.5 第二轮：空行结构复测 + U+2028 写回（22:24–22:36，分支 `mfang0126/be-nice-fix-linebreaks`）

**修复 1（无 GUI，提交 ad9139d）**：`hasRichContent` 读 AXRole 失败时以前只跳过 role、仍追加 subrole，两个数组错位后 `paragraphsRestorable` 返回 true，可能放行替换。改为失败时追加 `""` 保持对齐；第 0 层任何非 AXGroup 或读不到的 role 都不可还原。3 条新单测在 58879c9 上失败（scratch worktree，已删）。第二轮里这个函数换成了 `paragraphLayout`，规则不变：第 0 层只认 AXGroup，subrole 只认 `""` 和 `AXEmptyGroup`，读不到或数组错位一律只给复制。

**空行结构实测**（频道 #all-mingfangtech，安装版，只读 AX 转储 + 截图；本输入框 Return 发送、Shift+Return 换行，所以“用户手打空行”是 Shift+Return 两次）：

| # | 写法 | AXTextArea 下（段 = AXGroup，空 = AXGroup(`AXEmptyGroup`)） | AXValue |
|---|---|---|---|
| a | 用户手打三段，段间 Shift+Return ×2 | 段 / 空 / 段 / 空 / 段 | `a\nb\nc` |
| b | LCU `setValue("a\nb\nc")` | 段 / 空 / 段 / 空 / 段（截图有空行，与 a 相同） | `a\nb\nc` |
| c | LCU `setValue("a\n\nb")` | 段 / 空 / 空 / 段（截图两行空） | `a\n\nb` |
| — | 用户手打 Shift+Return 三行 | 段 / 段 / 段 | `a\nb\nc` |
| — | `a`+U+2028×2+`b` | 段 / 空 / 段 | `a\nb` |
| — | `a`+U+2028×3+`b` | 段 / 空 / 空 / 段 | `a\n\nb` |
| — | U+2028×2 + `a` + U+2028×2 | 空 / 空 / 段 / 空 / 空 | `\n\na\n\n` |

规律（所有行都符合）：
- **AXValue**：每个空段读成一个 `\n`；两个文字段直接相邻时中间补一个 `\n`。所以“段段”和“段 空 段”都读成 `a\nb`，只看 AXValue 无法还原，这是 Shift+Return 撤销后多出空行的根因。
- **U+2028 写入**：Slack 在每个 U+2028 处另起一段，空段写成空字符串。按段落列表用 U+2028 连接，上表所有结构都能原样重建，包括双空行、段首和段尾空段。
- **`\n` 写入**：k 个连续 `\n` 得到 k 个空段，相邻文字段写不出来。
- 6.5 f1 和 7.1 的矛盾由此解释：f1 当时写的是 `\n\n`，所以是 2 个空段。

**修法（`WriteBack.swift`）**
- capture 时（仅 Slack）读输入框第 0 层子节点，得到段落结构（`paragraphLayout`）。结构读不到、含非段落子节点，或与 AXValue 对不上（`slackEncoding(value:layout:)` 返回 nil）时，只给 Copy rewrite。预览前、替换前复核结构没变，变了按 `valueChanged` 拒绝。
- 撤销：按捕获的结构，用 U+2028 连接各段（空段为空串）后整篇写回。读回仍比对原 AXValue。
- 替换：建议里每个 `\n` 都写成 U+2028，所以单换行是软换行、空一行是一个空段，和卡片上看到的一致。读回比对按上面的 AXValue 规律算出的期望值（`slackNormalized`）。建议和原文读回一样（只差空行）时按“没有变化”拒绝，避免撤销无法区分。
- 读回：写 U+2028 后约 0.2 s 内 AXValue 是写入的原串（U+2028 还在），之后才拆段。第一次实测因此报 “box changed unexpectedly”。现在把“写入的原串”当作和旧值一样的“还没生效”，继续等；其他任何第三个值仍立即停止。只对 Slack 生效。
- 单测：WriteBackTests 第 30 组改写，含上表 4 种实测结构的 AXValue 模型和编码、替换后撤销还原 4 种结构、写入中间值、读回相同拒绝、结构变化拒绝、结构读不到只给复制。去掉中间值放行后 4 条失败（已验证）。`run-tests.sh` ALL PASS。

**真实 Slack 复测**（最终安装版，debug-status = 0，截图 + AX 子树）

| # | 位置 | 草稿 | 入口 | 替换后 | 撤销后 | 结论 |
|---|---|---|---|---|---|---|
| a | 频道 | Shift+Return 三行（逐字输入，段/段/段） | **Replace with Polite**（以前只给 Copy）。卡片改成 “…build⏎and the documentation⏎⏎before lunch?” | 截图：前两行紧挨，后面空一行；子树 段/段/空/段；状态 Replaced | 截图三行紧挨；子树 段/段/段；AXValue 逐字一致 | 通过 |
| b | 频道 | 三段，段间 Shift+Return ×2（段/空/段/空/段） | Replace with Polite（模型给单行） | 单段 | 子树 段/空/段/空/段，截图同替换前，AXValue 逐字一致 | 通过 |
| c | 频道 | 单行 | Replace with Polite | `[be-nice test] Could you please check the build before lunch?` | 单行，逐字一致 | 通过 |
| d | 线程 | Shift+Return 两行 | Replace with Polite，卡片改成两行 | 截图两行紧挨 | 子树 段/段，AXValue 逐字一致 | 通过 |

**发送测试（用户授权的唯一一条，LCU 按 Return 发送，不是 be-nice 发的）**：频道草稿 Shift+Return 两行 → be-nice 替换为 `[be-nice test] u2028 check` + 软换行 + `This is the second line.`（输入框子树 段/段）→ 发送。消息显示为两行、中间无空行。AX 读回消息：两个 AXStaticText `[be-nice test] u2028 check`、`This is the second line.`，消息标题 `Ming Fang: [be-nice test] u2028 check This is the second line. 10:35 PM.`，**全部字符为 ASCII，没有 U+2028 或其他特殊字符**。没有用剪贴板复制（避免覆盖用户剪贴板），以 AX 读回为准。结论：U+2028 只在写入时用，Slack 存的是普通段落，发出去是普通换行，保留在 Replace 里。

**已知限制**：空格-only 的段落按文字段处理（未实测）；结构变化检查只比第 0 层。

清理：频道、线程输入框为空（AX 读回只剩一个空段）；DM 未碰（侧栏 “Drafts & sent 1” 不变）；开始时频道输入框里有一个空的有序列表 “1.”（无文字，前一轮列表测试留下），已在测试中清掉；`~/Applications/.be-nice-install.*` 已删；临时诊断日志代码已删除、未提交。除上面一条授权消息外未发送任何消息。GUI 使用时段 22:24–22:36。
