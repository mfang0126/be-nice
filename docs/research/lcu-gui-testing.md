# LCU 真实界面测试：怎么做、哪里会卡

> **谁要读**：模型不是 Opus 5.5（例如 Sonnet、Haiku、Codex）就先读完再动手；Opus 5.5 已经会，不用读。
> 2026-10-27 一次测试里，Sonnet 5.5 和 Codex 都因下面第 1、2 条卡死，Opus 5.5 没有。

## 动手前（必读，6 行）

1. **Slack 必须真的在最前面**：`open -a Slack`，再点一下输入框。被终端盖住时 Rewrite 按钮不出现，be-nice 也不响应。
2. **用 bundle ID 取 App**：`cua.getApp("com.benice.menubar.development")`，`timeout_ms` 设 60000。用应用名 `be-nice Development` 会失败；按钮窗口不在时报 `-10005 timeoutReached`，那是"窗口不存在"，不是 App 卡死。
3. **LCU 一次只看到 be-nice 的一个窗口**：输入框有焦点时看到的是 `✎ Rewrite` 按钮；输入框失焦（点一下 Slack 的 Messages 标签）时看到的是状态胶囊（Undo / Dismiss）。窗口变了就重新 `getApp`。
4. **读状态用 `getAXState({emit:false, disableDiffing:true})` 再用 `filter` 取需要的行**，不要整棵树打印（Slack 的树很长）。
5. **给输入框放文字**：`setValue` 不生效；用 `click` 输入框，再 `paste(text, {format:"text"})`；替换已有内容先 `pressKey("super+a")`。
6. **绝不点输入框以外的 Slack 内容**：我们曾因下标写错点到 "Edit Profile" 打开资料表单。每次用 `find` 按文字取下标，不要写死数字。

## 常用操作

| 目的 | 做法 |
|---|---|
| 触发 Rewrite | 点按钮（树里 index 1，`✎ Rewrite`）；LCU 的 `pressKey` 到不了全局快捷键，那要用 CGEvent，需用户授权 |
| 等卡片 | 轮询到出现 `style-2` / `primary`，约 1.5–2.6 s |
| 换风格 | 点 `style-N`，菜单项 ID 为 `pickStyle:`，选名字 |
| 一句话微调 | 点 `rewrite-tweak`，`typeText`，`pressKey("Return")` |
| 替换 | `pressKey("super+Return")`，之后用 Slack 的 AX 读回确认 |
| 撤销 | 失焦后绑定胶囊，点 `Undo`；读回应等于替换前 |
| 打开设置 | 取 be-nice 的菜单栏项 `be-nice Development` → `Settings…`（`openModelSettings`）；系统菜单栏图标 LCU 够不到 |
| 设置里改风格 | 三行各有名字框、说明框（文本框，`setValue` 直接填）和 `Presets` 菜单（项 ID `presetPicked:`）；`Restore defaults` 恢复三个默认；Save 前不落盘 |
| 关窗不替换 | `pressKey("Escape")` |

## 会污染环境的地方（测完要恢复）

- 在设置里 Save 会改写风格（UserDefaults `be-nice.styleSlots`）。测完点 `Restore defaults` 再 Save。
- 在设置里 Save 会切换 provider；测试前问清用户是否同意。
- 撤销要求焦点还在原输入框元素上：测试中点了 Slack 其他控件（例如打开资料表单）会让 Electron 重绘输入框，撤销会被安全检查拒绝（"Slack focus moved…"）。这是保护，不是 Bug；重新走一轮 Rewrite→替换→撤销即可。

## 小坑

- `getApp` 每次都会把整棵 AX 树打印出来，输出很吵，无法关闭；点击要传整数下标：`app.click(97)`，不是 `{elementIndex: 97}`。

- 点 `be-nice Development` 菜单后，菜单已经展开；再次读树取到的就是菜单，直接点 `Settings…`，不要再找菜单栏项（会报 `cannotClickOffscreenElement`）。
- 重装开发版前先 `pkill -TERM -f "be-nice Development.app/Contents/MacOS/benice"`；安装脚本会留下 `.be-nice-install.*/previous.app`，验证后删掉。

## 已知观察

- 偶发模型只返回 1 张卡（DeepInfra DeepSeek，一次）；Copilot 与大多数次数都是 3 张。
- 状态胶囊、菜单栏图标 LCU 够不到时，**先试失焦换窗口**，再考虑请用户点一下。
