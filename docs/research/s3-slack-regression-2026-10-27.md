# S3 Slack 回归 + 全新安装实测（2026-10-27）

> 环境：Slack 桌面版，测试工作区 `mingfang.tech`（只有用户一人）；开发版 `~/Applications/be-nice Development.app`，provider Copilot `gpt-4o-mini`。
> 用户 20:44 授权前台测试约 60 分钟。全部草稿为带 `[be-nice test]` 的合成文本，未发送任何消息。
> 操作：LCU 点击（Rewrite、Replace、Undo 胶囊）；读回：独立读取 Slack 输入框 AX 值（不经 be-nice）。
> 中断：20:51 屏幕自动锁定（`CGSSessionScreenIsLocked=true`），LCU 所有窗口 `cgWindowNotFound`，之后的用例未执行，见文末。

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
| D1 | `[be-nice test] 麻烦你明天之前看一下构建日志，有问题告诉我。`（粘贴） | Replace with Polite（直接替换） | **三张全是英文**，例：“Could you please take a look at the build log before tomorrow and let me know if there are any issues?” | 与 Polite 卡一致 | 与原文逐字一致 | 写回/撤销 通过；**保真失败（语言被改成英文）** |
| D1b | `[be-nice test] 这个需求我们下周再讨论吧，今天先把bug修了。`（粘贴） | Replace with Polite | 中文；Polite “我们下周再讨论这个需求吗？今天先修复这个bug吧。”（陈述变问句）；Shorter “下周再讨论需求，今天先修bug。” | 与 Polite 卡一致 | 逐字一致 | 写回/撤销 通过；保真有偏差（语气改成问句） |
| D3 | 17 行英文周报，含 `1.`–`13.` 编号行和空行（粘贴） | Replace with Polite（直接替换） | 三张卡均保留 13 条 | 读回为 15 行纯文本 “1. There were…” | AX 读回与替换前逐字一致 | 写回/撤销 通过；见下方说明 |

D3 说明：粘贴后 Slack 把 `1. ` 行自动转成有序列表、去掉空行（AX 值变成 `1.The …`）。be-nice 仍判为纯文本、给直接替换，写回的是带 `1. ` 的纯文本行。撤销后 AX 字符串一致，但 AX 字符串无法区分“有序列表”和“纯文本 1.”，列表格式是否被恢复**未验证**（截图前屏幕已锁）。

所有用例：三张卡都把 `[be-nice test]` 标记删掉了（全新安装那次也一样）。点 Replace 时 LCU 报 `AXError.failure`（窗口在点击中关闭），替换本身成功。

## 3. 未执行（屏幕锁定）

- 私聊：IME 输入中文、带 @提及、带链接的草稿（富内容应走 Copy rewrite）。
- 线程回复输入框、频道输入框（#all-mingfangtech）中英文各一。
- 清理：DM 输入框当前是合成草稿 D3 原文，需要恢复原草稿；#all-mingfangtech 输入框是合成草稿 `[be-nice test] Can you check the build logs before tomorrow?`。

## 修复建议（本任务不改代码）

1. 提示词要求“保持草稿语言”，并校验输出语言与原文一致（D1）。
2. 方括号标签类前缀（如 `[be-nice test]`、`[WIP]`）被删除：提示词要求保留原有标签/前缀。
3. 有序/无序列表应视为富内容（走 Copy rewrite），或写回前检测 Slack 列表结构；补一条 AX 结构探测。
4. 设置页第 1 次 Test 只加载模型时，状态行应提示“Loaded. Click Test again to send a test request.”，或直接接着发测试请求。
