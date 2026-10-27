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
| D3 | 17 行英文周报，含 `1.`–`13.` 编号行和空行（粘贴） | Replace with Polite（直接替换） | 三张卡均保留 13 条 | 15 行纯文本 “1. There were…” | AX 字符串一致，**但截图显示有序列表没了**，变成 “1.The …” 段落（数字后无空格） | **失败**：列表被当纯文本直接替换；撤销没有恢复列表格式 |
| D4 | `[be-nice test] can you review the parser fix today @Ming Fang please`（`@Ming` + Tab 生成真提及胶囊） | **Replace with Polite（未识别为富内容）** | 第 1 次 “Would you be able to review the parser fix today, please, @Ming Fang?”；第 2 次 Polite 写成 “…please, Ming Fang?”（@ 都没了） | 截图：提及胶囊消失，变纯文本 | AX 一致，截图提及胶囊恢复 | **失败**：提及未被检测，替换丢掉提及；撤销能恢复 |
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
| T1 | `[be-nice test] Thanks, I will look at it after lunch.`（粘贴进 “Reply to thread in all-mingfangtech”） | **失败：Rewrite 按钮不出现**。线程输入框有焦点、有文字（截图确认），连续两次重新点输入框后 be-nice 无任何窗口（LCU `timeoutReached`）；同时间点频道主输入框能出按钮。T2（中文）因入口不出现未跑。全局快捷键 LCU 发不了，未测 |

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
