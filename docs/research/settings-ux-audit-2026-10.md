# Settings 界面 UI/UX 检查（2026-10）

> 状态：**只看代码的审计，全部条目都是据代码推断**，还没有一条在真实界面上观察到。“依据”一列的“源码”表示代码路径确定，“推测”表示视觉或体验上的判断；两种都还没有界面证据。
> 为什么没有截图（2026-10-29 17:11–18:40）：LCU 的 `getApp("be-nice Development")` 和按路径 attach 都超时（-10005），没有出现授权提示；`cua.listApps()` 的列表里根本没有 be-nice（它是只在菜单栏显示的 LSUIElement App）。没有点击任何界面，也没有保存任何设置。下一步：用户批准 LCU 权限后，用一个约 5 分钟的焦点窗口补截图，并把“推测”改成“观察到”或“不成立”。
> 范围：`mac-app/Sources/benice/SettingsWindow.swift`（854 行），入口在 `MenuBarShell.swift`，风格校验在 `RewriteOptions.swift`。只检查，不改代码。
> 构建：`sh mac-app/scripts/build-release.sh` 于 2026-10-29 17:0x 通过（ad-hoc 签名，0.2.0）。已安装的开发版构建于 10-27 23:59，晚于最后一次源码改动（10-27 23:57），界面应与本分支一致。

## 结论先说

- 最大的问题是**Save 和 Test 的语义不清楚、代价没有说明**：Return 键在任何输入框里都直接 Save；Test 会花钱发一次真实请求，但界面没有提示；Copilot 首次使用要点两次 Test。
- 其次是**未保存的改动会被悄悄丢掉**：Close / Esc / 红色关闭按钮都不确认，也没有“有改动未保存”的标记。
- 布局问题：窗口高度跟着状态文字跳动；模型来源和风格两块没有分组；错误提示离出错的输入框很远。

## 控件清单（源码读出）

| 区域 | 控件 | 源码 |
|---|---|---|
| 顶部 | 分段控件 “GitHub Copilot / Custom”，没有标题文字 | `SettingsWindow.swift:239-240`、`:376-379` |
| Copilot 面板 | 灰色状态文字 + “Model” 弹出菜单（宽 260） | `:241-252`、`:381-385` |
| Custom 面板 | Base URL / Model / API key 三行表格，输入框宽 340；API key 是 `NSSecureTextField` | `:254-270` |
| 风格 | 粗体标题 “Your three styles”；3 行 = 行号标签（“1 (default)”, “2”, “3”）+ 名称（宽 120）+ 指令（宽 ≥220）+ “Presets” 下拉（宽 96） | `:387-416` |
| 风格 | “Restore defaults” 按钮（单独一行，左对齐） | `:417-420` |
| 底部 | 状态文字（小号灰色，出错变红） | `:422-425` |
| 底部 | 右对齐 Close / Test / Save；Save = Return，Close = Esc | `:280-299`、`:427-433` |
| 窗口 | 标题 “Be Nice Settings”；`[.titled, .closable]`，不可缩放、不可最小化；内容宽 560 + 边距 40；高度按内容自动调整 | `:321-334`、`:471-478` |

Presets 共 7 个：Direct、Friendly、Clear、Shorter、Formal、Polished English、Polite；默认三行是 Polite / Shorter / Friendly（`RewriteOptions.swift:13-29`）。

校验规则：Base URL 必须 https（localhost 可 http），不能带 query、fragment 或账号密码；Model 不能空；没有已存的 key 时 API key 不能空（`SettingsWindow.swift:15-73`）。风格名 1–40 字，指令 1–200 字，不能换行、不能含 `<` 标签，三个名字不能重复（不分大小写）（`RewriteOptions.swift:66-86`）。

## 问题清单

“依据”一列：**源码** = 从代码读出、确定会发生；**推测** = 视觉或体验上的判断，要看到界面才能确认。截图一列在界面检查后补。

| # | 问题 | 在哪（文件:行） | 现象 | 为什么是问题 | 严重度 | 建议改法 | 依据 | 截图 |
|---|---|---|---|---|---|---|---|---|
| 1 | Return 在任何输入框里都触发 Save | `SettingsWindow.swift:283-284` | 用户改完一行风格指令按 Return，想“确认这一格”，结果整页（模型来源 + 三行风格）都被保存 | HIG：偏好设置窗口一般即改即生效，或者要明确点按钮才提交；表单里的 Return 默认保存，只适合单一用途的小对话框。这里一个窗口里有两类设置，误存的代价高 | P1 | 去掉 Save 的 `keyEquivalent "\r"`；或者把 Return 限定在 API key 一个框里（它本来就设了 delegate） | 源码 | 待补 |
| 2 | Close / Esc / 红色关闭按钮直接丢弃未保存改动，不提示 | `:294-299`、`:357-360`、`:844-846`；重新打开时 `reload()` 覆盖（`:345-347`、`:581-603`） | 改了风格或 URL 后按 Esc，窗口关掉；再打开时改动没了，也没有任何提示 | HIG：有显式 Save 的窗口，关闭时如果有未保存改动，要提示保存或放弃。Esc 现在等于“取消”，容易误按 | P1 | 记录“有改动”（与上次加载的值比较）；有改动时关闭弹出“保存 / 不保存 / 取消”；或者改成即改即存（见第 13 条） | 源码 | 待补 |
| 3 | Copilot 首次使用要点两次 Test，而且第一次 Test 没有在测东西 | `:505`、`:598-601`、`:779-783` | 首次打开显示 “Click Test to check your GitHub login and load the models.”；点 Test 只加载模型列表，然后提示 “Models loaded. Click Test again to send one test request.” | 同一个按钮在不同状态下做不同的事，用户不知道点了以后会发生什么。“Test”这个词说的是测试，第一次点却只是加载列表 | P1 | 选中 Copilot 时就自动加载模型列表（只调本机 `gh`，不发模型请求）；Test 永远只做“发一次真实请求” | 源码 | 待补 |
| 4 | Test 会发一次真实付费请求，界面没有说明 | `:192`、`:197-200`、`:778` | Test 会把一段固定示例文本发给模型，用的是三行风格；按钮没有说明，也没有 tooltip | 付费或有配额的操作要事先说明（HIG：说明操作的后果）。README 有隐私说明，但界面上没有 | P2 | 按钮旁加一行小字或 tooltip：“发送一段示例文本到所选模型（会消耗一次请求），不发送你的草稿”；如果第 3 条照做，可以改名为 “Send test request” | 源码 | 待补 |
| 5 | 错误提示只显示在窗口底部的状态行，离出错的输入框很远，也不定位焦点 | `:700-728`、`:838-842` | 例如 “Style 2 needs a name…” 或 “Base URL must be an https URL…” 出现在 Save 上方；出错的输入框没有高亮，焦点不移过去 | HIG / 表单常识：错误应在出错的控件旁边说明，并把焦点移到第一个出错的地方 | P1 | 校验失败时 `makeFirstResponder` 到出错的字段；在字段旁边或下方显示错误（至少把焦点移过去） | 源码 | 待补 |
| 6 | 有两处状态文字，各管各的 | Copilot 状态 `:241`、`:547-551`；全局状态 `:278`、`:838-842` | 在 Copilot 下，GitHub 登录错误显示在上方的面板里，Test / Save 的结果显示在底部；两处可能同时有字，颜色也可能不同 | 消息分散，用户不知道该看哪里；“Using your GitHub login.” 和 “Saved.” 可能同时出现 | P2 | 把模型来源的状态并进一个状态区；或者面板里只放持续状态（已登录 / 未登录），所有一次性结果都放到底部 | 源码；同时出现的样子是推测 | 待补 |
| 7 | 窗口高度随状态文字跳动 | `:471-478`，在 `:491`、`:550`、`:841` 调用 | 每次 `show()` / `setCopilotStatus()` 都会重新计算高度；文字从一行变两行，或者变空，窗口底边就上下跳，按钮也跟着移动 | 按钮在用户正要点的时候移位，会点错；视觉不稳定 | P2 | 给状态区固定最小高度（例如两行），只有切换模型来源时才调整窗口高度 | 源码；跳动幅度是推测 | 待补 |
| 8 | “Saved.” / “Defaults restored…” 之类的提示在之后编辑时不清除 | `:576`、`:770`、`:838-842` | 保存后再改字段，底部仍显示 “Saved.”，看起来像改动已保存 | 状态和实际不一致，会误导用户（和第 2 条叠加：用户以为保存了，关掉就丢了） | P2 | 在 `controlTextDidChange` 和 preset / provider 变化时清除成功提示 | 源码 | 待补 |
| 9 | 没有 Undo（⌘Z） | `MenuBarShell.swift:115-126` | Edit 菜单只有 Cut / Copy / Paste / Select All；文本框里 ⌘Z 没有对应的菜单项，可能不生效 | 常识：文本编辑要能撤销，尤其是 Presets 会整行覆盖名称和指令，Restore defaults 会覆盖三行 | P2 | Edit 菜单加 Undo / Redo（`undo:` / `redo:`，⌘Z / ⇧⌘Z）；以后改为即改即存时，Restore defaults 至少要能撤销 | 源码；⌘Z 实际是否生效待验证 | 待补 |
| 10 | Presets 选了直接覆盖这一行，不提示 | `:566-572` | 用户在第 2 行写了自定义指令，误选一个 preset，原文就没了 | 覆盖用户输入又不能撤销（第 9 条），丢失的是用户写的内容 | P2 | 做了第 9 条的 Undo 就够了；或者只在这一行是空的或等于某个 preset 时才直接覆盖 | 源码 | 待补 |
| 11 | Restore defaults 的作用范围不清楚，位置也容易误会 | `:276`、`:417-420`、`:574-577`；在 stack 里排在风格表下面 `:435-437` | 按钮单独一行、左对齐，名字没说只恢复风格；实际只恢复三行风格，不动模型来源 | 用户可能以为它会恢复全部设置（包括模型），或者担心它会清掉 API key | P2 | 改名为 “Restore default styles”，和风格标题放在同一行右侧 | 源码；误会是推测 | 待补 |
| 12 | 分组和层级弱：模型来源没有标题，两块设置之间没有分隔 | `:387-388`、`:435-441` | 第一行就是分段控件，没有 “Model” 或 “Send drafts to” 标题；风格有粗体标题，模型这块没有；整个窗口是一列，间距统一 14 | HIG（Settings 窗口）：相关设置分组并加标题；两类设置最好分 tab 或加分组框 | P2 | 加 “Model” 节标题，两节之间加分隔线；以后设置变多时改成 tab（General / Model / Styles） | 源码；视觉效果是推测 | 待补 |
| 13 | 用的是“显式 Save”模式，不是 macOS 设置窗口常见的即改即生效 | 整个窗口 `:280-299`、`:730-775` | 改了要点 Save；有 Close 按钮 | HIG：Settings 窗口一般即改即生效，不放 OK / Cancel / Save，用红色按钮关闭。这里显式 Save 有理由（Keychain 写入可能失败或要授权，Custom 要先校验），但它带来了第 1、2、8 条的问题 | P3（设计取舍） | 短期：保留 Save，修第 1、2、8 条。长期：风格行改为离开字段时自动保存，只有模型来源这一块保留 Save / Test | 源码 | — |
| 14 | 风格行号标签 “1 (default)” 没有解释“default”是什么意思 | `:389`、`:416` | 第一行的标签是 “1 (default)”，列宽固定 80 | 用户不知道 default 指的是“改写窗口里第一张卡 / 默认选中的那张”。另外 “1 (default)” 在 80 宽里可能显得挤 | P3 | 在 “Your three styles” 下面加一行说明，例如 “Each rewrite shows these three versions. Style 1 is selected first.”（以真实行为为准） | 源码；挤不挤是推测 | 待补 |
| 15 | Custom 面板的 Model 输入框占位文字是小写 “model name”，没有例子 | `:372` | Base URL 有例子 `https://api.example.com`，Model 只有 “model name”；API key 的占位文字会变（“Checking Keychain…” / “Stored in Keychain; leave blank to keep” / “Required”） | 不一致；不知道应该填什么格式（例如 `gpt-4o-mini`）。“Required” 当占位文字，输入后就看不到了 | P3 | Model 用例子 “e.g. gpt-4o-mini”；API key 是否已存、是否必填的说明放在字段下方 | 源码 | 待补 |
| 16 | 不可调整大小，固定内容宽度 560 | `:234`、`:323`、`:447` | 窗口宽 600，不能拉宽；指令输入框只有一行 | 指令最长 200 字，一行显示不完，要横向滚动看；固定宽度本身符合 Settings 窗口惯例 | P3 | 指令字段改为两行可换行的输入框（仍然禁止回车换行），或者加 tooltip 显示全文 | 源码；看不全是推测 | 待补 |
| 17 | 中文界面不存在 | 全部字符串都直接写在代码里，仓库没有 `.lproj` / `.strings` | 所有文字都是英文 | 产品主要用户写中文草稿（主回归用例 4），但设置界面只有英文。不算 bug，是范围问题 | P3（范围） | 不在本轮范围；要做的话先写进 PLAN | 源码 | — |
| 18 | 深色模式：没有写死的颜色，应该自动适配 | `:381-382`、`:422-423`、`:548`、`:839` 只用系统语义色（`secondaryLabelColor`、`systemRed`） | — | — | — | 无需修改；待截图确认 | 推测（预计没问题） | 待补 |

## 键盘导航（源码读出）

- 初始焦点在分段控件（`:457`）；Tab 顺序：模型来源 → Copilot Model → Base URL → Model → API key → 每行 名称 / 指令 / Presets → Restore defaults → Close → Test → Save → 回到开头（`:458-461`）。隐藏的面板会被跳过。
- 分段控件、弹出菜单、按钮能不能用 Tab 选中，取决于系统“键盘导航”设置；默认关闭时，Tab 只在文本框之间移动（推测，待验证）。
- ⌘, 在 be-nice 的窗口是前台窗口时可以打开 Settings（`MenuBarShell.swift:105-106`）；菜单栏菜单里也有 “Settings…” ⌘,（`:159-160`）。
- ⌘W 没有菜单项，可能关不了窗口（推测，待验证）。如果确实关不了：P3，在 App 菜单或 File 菜单加 Close Window ⌘W。

## 建议修复顺序

1. 第 1 条（Return = Save）和第 2 条（关闭不提示），两条都是数据安全问题，改动小。
2. 第 3、4 条（Test 的语义和代价）：选 Copilot 时自动加载列表，Test 只做测试，并说明会发一次请求。
3. 第 5、8 条（错误定位、清除过期提示）。
4. 第 6、7 条（统一状态区、固定高度）。
5. 第 9–12 条（Undo、Presets 覆盖、Restore defaults 改名、分组标题）。
6. 其余 P3 留到后续，第 17 条要先写进 PLAN。

## 待界面确认

LCU 授权后在一个约 5 分钟的焦点窗口里做：打开 Settings；切换 Copilot / Custom；清空字段和输入重复风格名后点 Test，触发校验错误（校验失败时不会发网络请求）；Presets；Restore defaults；Tab 键遍历；浅色和深色模式截图（结束后切回浅色）。不点 Save，不发真实 Test 请求，不碰 Keychain 和 Slack，最后点 Close，什么都不保存。截图存到 `docs/research/settings-ux-audit/`。
