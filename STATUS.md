# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-27 21:42 AEDT

## 阶段：S3 Slack 专项回归（已跑一轮，有失败项，未交付）

证据：[docs/research/s3-slack-regression-2026-10-27.md](docs/research/s3-slack-regression-2026-10-27.md)（20:47–21:01，真实 Slack，LCU 操作 + 独立 AX 读回，用户授权前台时段）。

通过：
- 全新安装路径（PLAN 体验改进第 6 项）：清空开发版 UserDefaults 后点 Rewrite，只打开设置页，状态 “Choose where your drafts are sent. Nothing is sent until you Save.”；点 Test 之前 be-nice 子进程 `gh` 0 次、网络 0 行；Test（第 2 次点才发测试请求，1.2 s）→ Save → 三张卡正常。之后 UserDefaults 从备份恢复，`diff` 为空。
- 私聊：中文粘贴、中文逐字输入、17 行长文的替换 + 读回 + 撤销（AX 字符串）都一致；带链接草稿识别为富内容，只给 Copy rewrite。
- 频道 #all-mingfangtech 主输入框：中英文各一条，替换、读回、撤销逐字一致。

修复 A（分支 `mfang0126/fix-rich-thread`，PR #10 未合并；证据文件第 6 节，21:10–21:28 三轮真实重跑）：
- 提及胶囊、有序列表现在识别为富内容，只给 Copy rewrite（频道实测）。富内容在替换前就被拒，不会出现“撤销后 AX 一致但列表丢了”的情况。
- 线程回复输入框出现 Rewrite；英文、中文各一条替换 + 读回 + 撤销逐字一致。原因：线程输入框的 AXWebArea 在第 18 层父节点，旧上限 16。
- 频道纯英文、三段带空行、Shift+Return 三行草稿仍直接替换，读回、撤销（AXValue）一致；加粗、行内代码（段中、段首、段尾、整段）只给 Copy rewrite。状态文案已提到列表和格式。
- 已知限制：单独成段的提及胶囊算纯文本；慢 Slack 下线程 Rewrite 按钮可能闪烁（只会不显示）。

修复 C（分支 `mfang0126/be-nice-fix-linebreaks`，PR 未合并；证据文件第 7 节，21:36–21:39 真实 Slack）：
- 原因：Slack 替换和撤销都用 setValue，Slack 把写入的每个 `\n` 变成“新段落 + 空行”。Shift+Return 的行（相邻段落）无法用 `\n` 还原。
- 修法：输入框段落结构不是“段 (空段 段)*”的草稿（Shift+Return 行、双空行、首尾空行）只给 Copy rewrite。单行、单空行分段仍然直接替换。
- 实测：频道、线程的 Shift+Return 草稿都只给 Copy；频道单空行三段、单行、线程单行的替换 + 撤销截图与 AX 一致。
- U+2028 探测：setValue 写 U+2028 得到与 Shift+Return 相同的结构，AXValue 读回 `\n`。以后可以按结构编码写回、保留软换行，这需要先写进 PLAN。

仍失败（未修，修法见证据文件“修复建议”）：
1. 语言：一条中文草稿三张卡全变英文（另两条中文正常），违反 PLAN“保持原文语言”。
2. 所有卡片都删掉方括号前缀（`[be-nice test]`）。


仍未测：真中文 IME 组字（LCU 只能逐字发送）；emoji；同名会话；窗口标题变化导致的误拒绝。

## 发布

- v0.1.0 预览版已公开：https://github.com/mfang0126/be-nice/releases/tag/v0.1.0 （仅 arm64，仅在 macOS 26 测过，无 Developer ID）。
- 体验改进 2–6 项已合入 main（PR #4–#7）。v0.1.0 发布说明未改，新内容写进下一个版本的说明。
- 后续开发从 main 开新分支，合并走 PR。

## 代码现状

- 界面文案英文；三个风格（默认 Polite / Shorter / Friendly）可在设置页编辑，存 `be-nice.styleSlots`。
- 设置页两种 provider：GitHub Copilot（用本机 `gh auth token`，App 不存 token）与 Custom（OpenAI 兼容）。全新安装不默认走任何 provider，Save 后才发请求。
- 安全写回核心 `WriteBack.swift`：替换/撤销前复核同一进程、同一输入框、原文未变、窗口标题未变。富内容检测（修复 A、C 后）：段落结构无法用 setValue 还原的多行草稿，emoji、链接、按钮、列表（AXList），一段被切成多段文字（提及胶囊、行内格式），以及子节点 subrole 以 `StyleGroup` 结尾（加粗、行内代码等）。
- 入口按钮贴 Slack 输入区右上角外侧；`TriggerPolicy.maxAncestorDepth` = 24（修复 A；频道输入框 AXWebArea 在第 16 层，线程在第 18 层）。

## 开发环境

- 开发版固定路径 `~/Applications/be-nice Development.app`，Bundle ID `com.benice.menubar.development`，本地签名证书指纹 `D933388477455C8C62344293E483E625F4B7B194`（不得重新生成）。旧的 `.be-nice-install.*` 目录已清（10-27 21:27），LCU 可用完整路径取 App。
- Accessibility 已授权，`python3 -I mac-app/scripts/debug-status.py` 返回 0。
- **开发版模型配置：provider Copilot，模型 `gpt-4o-mini`**（UserDefaults `be-nice.provider=copilot`）。UserDefaults 里仍留着旧的 DeepInfra base URL 和模型 ID，但不在用。测试不得覆盖该配置。
- 测试工作区 Slack `mingfang.tech`：DM（自己）里有一条来源未证实的未发送草稿 `hi, the numbers in the report look off…`，测试后已原样恢复；#all-mingfangtech 有一条已发送的 `[be-nice test] thread parent`（用户授权）。
- 长时间前台测试会被系统自动锁屏打断（10-27 20:51）；测试前先确认锁屏时间或保持唤醒。

## 下一步

1. 修复 A 的 PR #10：第三轮 review 意见已处理，待协调者确认后合并。
2. 修复 C 的 PR：待独立 review 后合并。是否做“U+2028 保留软换行替换”（Shift+Return 草稿目前只能复制）由用户决定，做的话先写进 PLAN。
3. 保持原文语言、保留方括号前缀（另一 worker 负责）修完后，重跑私聊用例（D1）。
4. 真 IME 组字测试需要用户在场切输入法。
