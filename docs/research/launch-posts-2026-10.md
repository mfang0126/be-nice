# Be Nice 发帖草稿（r/macapps / X / 其他 subreddit），2026-10

> 只是草稿，没有发帖。依据：[demand-2026-10.md](demand-2026-10.md) 第 3、4 节，以及 2026-10-29 读到的 r/macapps 规则原文。
> 产品事实全部来自 README.md（v0.2.0 preview）。不写用户数、star 数和下载量。
> 文案避免（调研第 4 节）：不说 "AI writes your messages"、"auto-reply"、"agent"；"对老板措辞"不当主打；"撤销"不放标题。

## 0. 发帖前要确认的事实

| 项 | 当前值（2026-10-29 查） | 发帖前要做 |
|---|---|---|
| 下载地址 | `https://github.com/mfang0126/be-nice/releases`，v0.2.0 现在标的是 **Pre-release** | 确认要发的版本和 zip 名（`BeNice-0.2.0-macos.zip`） |
| 仓库 | 2026-10-23 创建，MIT | — |
| 公证 | 未公证，没有 Apple Developer ID | 正文里写清"右键 → 打开" |
| 系统 | 要求 macOS 13+，只在 macOS 26 上测过 | 原样写 |
| 竞品价格 | Grammarly Pro $12/月、Vibe Shift Pro $9.99/月（官网）；RewriteBar $29（来自 r/macapps 测评，没在官网核对） | 发帖当天到官网再核一遍，对不上就删掉那一项 |

## 1. r/macapps

### 1.1 发帖前清单（规则原文）

- [ ] **先确认能不能发主版**。规则原文见 [Phase 3 公告（2026-03-19）](https://www.reddit.com/r/macapps/comments/1ryaeex/rmacapps_mods_went_too_far_whats_changing_phase_3/)：
  - Tier 1（Trust）：Mac App Store 开发者，或已经成熟的 GitHub 项目（"1yr old repo OR 100+ stars"），或有开发者 flair。**Be Nice 现在一条都不满足**：仓库 2026-10-23 才创建，star 数不到 100。
  - Tier 2（Transparency）：帖子里**同时**给出 ① 带真实身份的开发者主页（LinkedIn、真实联系方式），② 一个有 Privacy Policy 和 Terms of Service 的网站。**现在没有项目网站**，要先做一个（比如 GitHub Pages 加隐私政策和条款页；版主认不认这种做法属推测，可以先 modmail 问）。
  - Tier 3：上面两条都不满足，就只能发每月的 **"The App Pile" Megathread**。
  - 结论：**按现状只能发 Megathread**（见 1.3）。补齐 Tier 2 材料后，才能用 1.2 发主版。
- [ ] **本版 karma ≥ 10**：先在 r/macapps 正常评论攒够（规则 Rule 1："10pt LOCAL Karma Required"）。
- [ ] **先标记已读规则、拿到发帖权限**：按 [How to gain post approval](https://www.reddit.com/r/macapps/comments/1smg62t/how_to_gain_post_approval_in_rmacapps_with_read/) 操作。原文警告："Read ALL rules first. Otherwise, your post is likely to be removed (80–90% probability) and trigger a 30-day cooldown under Rule 3."
- [ ] **30 天一次**（Rule 3）："not permitted more than once per developer in 30 days. This is counted from the last app post, even if it was removed." 帖子被删了也算一次，所以第一次就要发对。
- [ ] **格式 PCP**：正文必须有 Problem、Comparison（点名 1–2 个主要竞品）、Pricing（价格加链接）。
- [ ] **标题**加 `[OS]` 前缀；flair 选 **Free**。
- [ ] **下载链接**只放官方渠道（GitHub Releases）（Rule 2）；**不用短链**（Rule 5）；不放推荐/邀请链接（Rule 6）。
- [ ] **声明是开发者本人**（Rule 3："Always disclose your relationship to your software"）。
- [ ] 附一张截图或一个 GIF（可用 `docs/screenshot.png`，里面是合成草稿）。

### 1.2 主版帖（满足 Tier 2 后用）

**标题：**

```
[OS] Be Nice – rewrite your Slack draft in place, three ways, before you hit send (free, MIT)
```

**正文：**

```
Hi r/MacApps — I'm the developer. Be Nice is a small menu-bar app for the Slack desktop app.

**Problem**
My Slack messages often read harsher than I mean them. "Can you send the report today" sounds fine in my head and blunt on screen. My fix used to be: copy the draft, paste it into a chatbot, ask for a softer version, copy it back, paste it into Slack. For one message.

**What it does**
- Type your draft in Slack as usual. Click the Rewrite button above the message box, or press ⌃⌥⌘Space.
- You get three versions of the whole draft: Polite, Shorter, Friendly (you can rename or change these styles).
- Pick one, edit it if you like, confirm. It replaces your draft in the message box.
- An Undo button puts your original text back.
- It never sends anything. You still press Enter yourself.

**Comparison**
- Grammarly Pro ($12/mo) includes tone adjustment as part of a paid writing subscription. Be Nice is free, does one thing, and shows three whole-draft versions side by side.
- Vibe Shift ($9.99/mo Pro) is a Slack slash-command app installed into the workspace. Be Nice runs on your Mac, needs no workspace install, and works with the model you choose.

**Pricing**
Free, MIT licensed. Source and releases: https://github.com/mfang0126/be-nice
There is no paid tier. You bring the model.

**Privacy / model**
- Be Nice has no server of its own and bundles no model.
- Nothing is sent until you choose a provider and click Save.
- Providers: GitHub Copilot (uses your existing `gh` login; the token is not stored), or any OpenAI-compatible endpoint, including Ollama or LM Studio on your own Mac. API keys go into your Keychain.
- Your draft goes only to the provider you picked. With a local model it stays on your Mac.

**Install notes**
- Download the zip from GitHub Releases (link above), move Be Nice.app to /Applications.
- It isn't notarized (I don't have an Apple Developer ID yet). The first time, right-click → Open.
- It needs Accessibility access to read and replace the text in Slack's message box.
- macOS 13+; so far tested on macOS 26 only.

**Limits (early preview, v0.2.0)**
- Slack desktop only. Drafts with links, mentions, lists or formatting are copy-only: it never replaces those.
- If it can't safely confirm the target message box, it refuses to replace and offers copy only.

Developer portfolio: <LinkedIn / 个人主页链接>
Website (privacy policy + terms): <项目网站链接>

Feedback very welcome, especially on styles you'd want by default.
```

> 尖括号里的两项是 Tier 2 的必填项。补齐之前不要发主版。

### 1.3 Megathread 版（按现状用这个）

发在当月 "The App Pile" Megathread 下面，作为一条评论：

```
[OS] Be Nice – free, MIT menu-bar app for the Slack desktop app (I'm the developer)

Problem: my Slack drafts often read harsher than I mean them, and fixing that meant copy → chatbot → copy back → paste.
What it does: press ⌃⌥⌘Space on a draft and get three whole-draft versions (Polite / Shorter / Friendly). Pick one, edit, confirm, and it replaces the draft in place. Undo restores your original. It never sends; you do.
Comparison: Grammarly Pro ($12/mo) bundles tone adjustment into a paid subscription; Vibe Shift ($9.99/mo) is a workspace slash-command app. Be Nice runs locally on your Mac with the model you choose.
Pricing: free, no paid tier.
Privacy: no server of its own, no bundled model. Your draft goes only to the provider you pick (GitHub Copilot or any OpenAI-compatible endpoint, including Ollama/LM Studio on your Mac).
Install: GitHub Releases → https://github.com/mfang0126/be-nice/releases. Not notarized, so right-click → Open the first time. Needs Accessibility access. macOS 13+, tested on macOS 26.
Early preview: Slack desktop only; rich drafts (links, mentions, lists) are copy-only.
```

## 2. X

### 2.1 英文版

主帖：

```
My Slack messages read harsher than I mean them.

So I built Be Nice: a tiny macOS menu-bar app. Press ⌃⌥⌘Space on your draft, pick Polite / Shorter / Friendly, and it replaces the text in place. You still hit send.

Free, open source. Works with your own model or Ollama.
```

第一条回复（链接放回复里）：

```
GitHub: https://github.com/mfang0126/be-nice
Slack desktop only for now, early preview. Not notarized yet, so right-click → Open the first time.
```

### 2.2 中文版

主帖：

```
我的 Slack 消息，读起来总比我想的要冲。

于是做了个 macOS 菜单栏小工具 Be Nice：草稿写好按 ⌃⌥⌘Space，挑「客气 / 更短 / 友好」其中一版，原地替换。最后还是你自己按发送。

免费开源，可以用自己的模型或本地 Ollama。
```

第一条回复：

```
GitHub：https://github.com/mfang0126/be-nice
目前只支持 Slack 桌面版，早期预览。还没公证，第一次打开请右键 → 打开。
```

### 2.3 15 秒演示视频分镜

全程只用**合成测试草稿**和测试频道，不出现真实同事、真实频道名或真实消息（遵守 AGENTS.md 的真实测试规则）。录屏放在用户交出的焦点窗口里做。

| 镜头 | 时长 | 画面 | 屏幕字幕（EN / 中） |
|---|---|---|---|
| 1 | 0–3s | Slack 输入框里有一条合成的生硬草稿，例如 `need the deck by 3. why isn't it done yet` | "Sounds harsher than I meant." / "本意没这么冲。" |
| 2 | 3–7s | 按 ⌃⌥⌘Space（角落显示按键提示），改写窗口弹出三张卡：Polite / Shorter / Friendly | "Three versions, one shortcut." / "一个快捷键，三个版本。" |
| 3 | 7–11s | 镜头停在 **Shorter** 卡上，选中它，点确认，输入框里的草稿被替换成短版 | "Pick one. Replaced in place." / "选一个，原地替换。" |
| 4 | 11–15s | 点 Undo，原稿回来；再换成 Polite 版，光标停在输入框，**不按发送**。最后一帧：`Be Nice · free, open source · github.com/mfang0126/be-nice` | "Undo anytime. You still hit send." / "随时撤销。发送还是你自己按。" |

备注：镜头 3 用 Shorter，正面回应"AI 把一句话写成一页"的抱怨（调研反面证据表）。字幕尽量少，不配音也能看懂。

## 3. 其他 subreddit

选择依据：规则明确允许分享自己的项目，并且和开源或独立开发相关。痛点社区（r/auscorp、r/remotework、r/managers）**不发**，那里反 AI 代写的情绪很重（调研第 1 节）。

### 3.1 r/SideProject

- 规则原文：[old.reddit.com/r/SideProject/about/rules](https://old.reddit.com/r/SideProject/about/rules)（侧栏写明 "a subreddit for sharing and receiving constructive feedback on side projects"；格式要求 "[Project name] - [Short description]"）。
- 预期：同类帖只有 0–3 赞（调研第 3 节）。适合收反馈，别指望流量。

**标题：**

```
Be Nice - a free, open-source Mac menu-bar app that rewrites your Slack draft in place before you send it
```

**正文：**

```
I kept getting the "your messages come across as blunt" thing, and my fix was copy → chatbot → copy back → paste. Every time.

Be Nice does that step inside Slack: press ⌃⌥⌘Space on a draft, get three versions (Polite / Shorter / Friendly), pick one, and it replaces the draft in the message box. There's an Undo, and it never sends anything for you.

- Free, MIT: https://github.com/mfang0126/be-nice
- Bring your own model: GitHub Copilot or any OpenAI-compatible endpoint, including Ollama on your Mac
- No server of its own; your draft only goes to the provider you pick
- Early preview: Slack desktop on macOS only, not notarized yet (right-click → Open)

What I'd love feedback on: are Polite / Shorter / Friendly the right three defaults? And would you use this in Teams or Discord too?
```

### 3.2 r/opensource

- 规则原文：[reddit.com/r/opensource/about/rules](https://www.reddit.com/r/opensource/about/rules)。要点："No Spam / Excessive self-promotion"（Reddit 建议自我推广不超过发帖的 10%，本版"a little more forgiving"）；"No Drive-By Posting / Karma Farming"；帖子要和开源"direct relevance"。
- 写法：讲开源本身（MIT、自带模型、无服务器、欢迎贡献），不写成广告。发帖账号最好在这里先有正常参与记录（规则针对 drive-by 账号）。

**标题：**

```
Be Nice: an MIT-licensed macOS app that rewrites Slack drafts with a model you choose (Copilot, any OpenAI-compatible API, or local Ollama)
```

**正文：**

```
I've open-sourced a small Swift menu-bar app I've been building: https://github.com/mfang0126/be-nice (MIT).

It reads your draft from the Slack desktop message box (via macOS Accessibility), asks the model you configured for three rewrites (Polite / Shorter / Friendly), and writes your pick back into the box. Undo restores the original. It never sends messages.

Open-source-relevant bits:
- No backend and no bundled model. You point it at GitHub Copilot or any OpenAI-compatible endpoint; Ollama / LM Studio on localhost work.
- API keys live in the macOS Keychain; nothing is sent until you choose a provider.
- The write-back is deliberately conservative: if it can't confirm the target box, or the draft has links, mentions or lists, it refuses to replace and offers copy only.
- Self-tests run with `sh mac-app/scripts/run-tests.sh`; contributor notes are in AGENTS.md.

It's an early preview (v0.2.0, unsigned/not notarized, Slack desktop only). Issues and PRs welcome, especially around other apps and accessibility edge cases.
```

## 4. 发帖顺序建议（推测）

1. 先发 X（不受 subreddit 规则限制），视频是重点。
2. r/macapps：按现状先发 Megathread 评论；以后有了网站、隐私政策和条款，或者仓库满足 Tier 1，再发主版。30 天只有一次机会，宁可等材料齐了再发。
3. r/SideProject 和 r/opensource 隔几天分开发，避免看起来像一次性刷屏。
