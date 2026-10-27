# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-27 16:20 AEDT

## 阶段：S1 Slack 安全写回（私聊已跑通，未交付）

2026-10-27 09:46 在真实 Slack 私聊（自己）中由 be-nice 完整走通：Rewrite → 三张卡片 → 替换 → 独立读回 → 撤销精确恢复，未发送消息（替换由 LCU 点击，撤销由用户点击，读回均经 LCU AX 确认）。

已解决的 S0 卡点：
- 会话身份：替换/撤销前复核同一进程、同一输入框元素、原文未变、窗口标题未变（`Ming Fang (DM) - mingfang.tech - Slack`）。同名会话无法区分（已知限制）。
- 入口不出现：输入框在 AXWebArea 下 10 层，祖先遍历从 8 层放宽到 16 层。
- 替换报 focusChanged：Slack 关窗后把焦点还给网页而非输入框；复核通过后对原输入框元素设 AXFocused，写入后也把焦点留在输入框。

仍未解决：
1. 富内容（emoji/提及/链接）已检测：只给复制、写入前再拒绝。10-27 10:13 实测：纯文本草稿仍为 “Replace with Direct”，带 emoji 草稿变为 “Copy rewrite”；测试草稿已精确恢复。提及和链接的 AX 结构尚未在真实 Slack 中验证。
2. 同一会话内窗口标题变化（如未读标记）会误拒绝替换，偏安全，待实测观察。
3. 中文 IME、长文、频道和线程（S3）未测。
4. 同一会话名重名无法区分（已知限制）。

## 发布

- v0.1.0 预览版已公开：https://github.com/mfang0126/be-nice/releases/tag/v0.1.0 （PR #1 合并为 main `361804c`，zip SHA-256 `69e3e112…4a30`，仅 arm64，仅在 macOS 26 测过，无 Developer ID）。
- 压缩后自动注入本文件、`git status --short` 与最近 5 次提交的 hook 已移到全局 `~/.claude/settings.json`（10-27 11:28；项目里有 STATUS.md 才注入）。PR #2 加的项目级副本已删除。
- 工作分支 `mfang0126/be-nice-m0-axprobe` 继续开发，合并走 PR。

## 代码现状

- 界面文案全部英文。三个风格位置可配置（默认 Direct / Friendly / Clear，存 UserDefaults `be-nice.styleSlots`），默认选中第一张。
- 改写窗口：设计 B「并排对比」，Slack 配色；原稿整宽浅灰框（最多 5 行，按真实排版测高）。
- 体验改进第 3 项已完成（10-27 15:20 已在真实设置窗口点过：Custom Test 0.8 s、Copilot Test 1.3 s、Save 成功；开发版现在走 Copilot gpt-4o-mini）：设置页两种 provider——GitHub Copilot（用本机 `gh auth token`，App 不登录/不存 token，模型取 `/models`，默认 gpt-4o-mini；实测三张卡 0.9 s）与 Custom（任意 OpenAI 兼容）；三个风格位置可在设置里改；Test 按钮。开发版已保存 custom 配置（DeepInfra），所以仍默认走 Custom，切到 Copilot 需在设置里点选后 Save。
- 体验改进第 5 项（Opus 独立 review 后，10-27 16:15 实测）：默认三个风格改为 Polite / Shorter / Friendly（旧默认且没改过的自动换新）；提示词不再把问句变命令、不加问候落款；微调栏写明对象；选中卡显示 “Edit, then ⌘↩”；关闭窗口不再弹旧 Undo；名称统一 Be Nice / Rewrite shortcut；设置按钮靠右。观察：Shorter 偶尔把问句缩成 “Please fix …”。
- 体验改进第 4 项（UI/UX 分析，10-27 16:20）：换风格只影响这一次、不再改默认；预设说明更有区分度并要求三版明显不同；微调栏有边框、大字；窗口贴着输入框出现（盖住更少对话）；底部提示收短。已在 Slack 私聊实测换风格不改默认；窗口位置请用户目测。设置页每个位置可 “Write your own…”（已提交 6a4bab3）。
- 体验改进第 2 项与 2b 已完成（10-27 15:10 已在 Slack 私聊 LCU 实测通过：换风格 1.7 s 只重写一张，微调 1.6 s 只重写选中卡，替换读回一致，撤销精确恢复，Copilot 三张卡 1.6 s；测试怎么做见 docs/research/lcu-gui-testing.md）：卡片风格名下拉换风格（6 预设 + 自写一句，只重写该卡片，成功后记入该位置）；“How should it change?” 一行微调，只重写选中卡片。DeepInfra 实测：三张 1.8 s、单张换风格 1.0 s、微调 0.7 s。Orca run `run_69e7a11e6a69`（两个 Sonnet worker）+ 独立 review 5 条均已修。
- 入口按钮贴 Slack 输入区盒子右上角外侧；状态胶囊同一行左对齐，32 pt 同高。
- 安全写回核心 `WriteBack.swift`；Slack 已加入两份允许列表。
- 开发版 API key 读 `~/Library/Application Support/be-nice/dev-api-key`（0600，仅 DEBUG 编译），避免每次重编译弹 Keychain 密码；正式版只用 Keychain。
- 个人风格学习代码保留但不在 UI；旧小绿点卡片、多 App 探针已删除（标签 `archive/multi-app-m0-m2`）。

## 开发环境

- 开发版固定路径 `~/Applications/be-nice Development.app`，Bundle ID `com.benice.menubar.development`，本地签名证书指纹 `D933388477455C8C62344293E483E625F4B7B194`（不得重新生成）。
- 10-26 00:03 用户已授予 Accessibility；10-27 00:30 重建安装新版（并排对比窗口）后，运行中的 App 报告 `accessibilityTrusted: true`，**重建后授权保留已验证**。使用前跑 `python3 -I mac-app/scripts/debug-status.py`（0=已授权，2=未授权，1=无法确认）。
- 开发版模型配置：DeepInfra `https://api.deepinfra.com/v1/openai` + `deepseek-ai/DeepSeek-V4.1-Flash`，密钥取自 `~/.hermes/.env`。丢失时运行 `sh mac-app/scripts/configure-dev-model.sh` 恢复（用户 10-27 指定为默认）。测试不得用别的值覆盖。

## 下一步

1. 真实 Slack 里还没测：中文 IME、长文、带 emoji/提及/链接的草稿。
2. 中文/英文普通草稿多跑几次私聊闭环，验证提及和链接被识别为富内容。
3. 频道与线程（S3）。
4. 同一会话标题变化导致的误拒绝，按实测决定是否放宽。
