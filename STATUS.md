# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-27 21:05 AEDT

## 阶段：S3 Slack 专项回归（已跑一轮，有失败项，未交付）

证据：[docs/research/s3-slack-regression-2026-10-27.md](docs/research/s3-slack-regression-2026-10-27.md)（20:47–21:01，真实 Slack，LCU 操作 + 独立 AX 读回，用户授权前台时段）。

通过：
- 全新安装路径（PLAN 体验改进第 6 项）：清空开发版 UserDefaults 后点 Rewrite，只打开设置页，状态 “Choose where your drafts are sent. Nothing is sent until you Save.”；点 Test 之前 be-nice 子进程 `gh` 0 次、网络 0 行；Test（第 2 次点才发测试请求，1.2 s）→ Save → 三张卡正常。之后 UserDefaults 从备份恢复，`diff` 为空。
- 私聊：中文粘贴、中文逐字输入、17 行长文的替换 + 读回 + 撤销（AX 字符串）都一致；带链接草稿识别为富内容，只给 Copy rewrite。
- 频道 #all-mingfangtech 主输入框：中英文各一条，替换、读回、撤销逐字一致。

失败（未修，修法见证据文件“修复建议”）：
1. 语言：一条中文草稿三张卡全变英文（另两条中文正常），违反 PLAN“保持原文语言”。
2. 提及胶囊未被识别为富内容：给了直接替换，替换后提及变纯文本（一次连 @ 都没了）；撤销后胶囊恢复。
3. 有序列表未被识别：直接替换；撤销后 AX 字符串一致，但界面上列表变普通段落（`1.The…`）。AX 字符串相等不能证明撤销精确。
4. 线程回复输入框不出现 Rewrite 按钮（两次），线程用例无法进行；同时频道主输入框正常。
5. 所有卡片都删掉方括号前缀（`[be-nice test]`）。

仍未测：真中文 IME 组字（LCU 只能逐字发送）；emoji；同名会话；窗口标题变化导致的误拒绝。

## 发布

- v0.1.0 预览版已公开：https://github.com/mfang0126/be-nice/releases/tag/v0.1.0 （仅 arm64，仅在 macOS 26 测过，无 Developer ID）。
- 体验改进 2–6 项已合入 main（PR #4–#7）。v0.1.0 发布说明未改，新内容写进下一个版本的说明。
- 后续开发从 main 开新分支，合并走 PR。

## 代码现状

- 界面文案英文；三个风格（默认 Polite / Shorter / Friendly）可在设置页编辑，存 `be-nice.styleSlots`。
- 设置页两种 provider：GitHub Copilot（用本机 `gh auth token`，App 不存 token）与 Custom（OpenAI 兼容）。全新安装不默认走任何 provider，Save 后才发请求。
- 安全写回核心 `WriteBack.swift`：替换/撤销前复核同一进程、同一输入框、原文未变、窗口标题未变。富内容检测目前只认出 emoji 和链接，认不出提及胶囊和列表。
- 入口按钮贴 Slack 输入区右上角外侧；`TriggerController` 祖先遍历上限 16 层。

## 开发环境

- 开发版固定路径 `~/Applications/be-nice Development.app`，Bundle ID `com.benice.menubar.development`，本地签名证书指纹 `D933388477455C8C62344293E483E625F4B7B194`（不得重新生成）。旧的 `.be-nice-install.*` 目录已清（10-27 21:01），LCU 可用完整路径取 App。
- Accessibility 已授权，`python3 -I mac-app/scripts/debug-status.py` 返回 0。
- **开发版模型配置：provider Copilot，模型 `gpt-4o-mini`**（UserDefaults `be-nice.provider=copilot`）。UserDefaults 里仍留着旧的 DeepInfra base URL 和模型 ID，但不在用。测试不得覆盖该配置。
- 测试工作区 Slack `mingfang.tech`：DM（自己）里有一条来源未证实的未发送草稿 `hi, the numbers in the report look off…`，测试后已原样恢复；#all-mingfangtech 有一条已发送的 `[be-nice test] thread parent`（用户授权）。
- 长时间前台测试会被系统自动锁屏打断（10-27 20:51）；测试前先确认锁屏时间或保持唤醒。

## 下一步

1. 待用户决定修复顺序：线程入口（先只读诊断祖先链）、提及/列表识别为富内容、保持原文语言、保留方括号前缀。
2. 修完后重跑 S3：私聊、频道、线程，富结构用截图辅助确认撤销。
3. 真 IME 组字测试需要用户在场切输入法。
