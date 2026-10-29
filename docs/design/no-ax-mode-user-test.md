# 零权限模式 — 用户实测步骤

> 目的：确认 A（服务菜单）在 Slack 桌面版里能不能**原地替换**，再在 TextEdit 和浏览器文本框各试一次；顺便试 B（剪贴板）。
> 规矩：只用合成草稿 `[be-nice test] hey can u send the file asap`，**不按 Enter、不发送**，测完删掉草稿。会用到真实模型（每次 1 个请求）。
> 全程约 10 分钟，需要你本人操作前台。

## 0. 准备（约 2 分钟）

1. 退出正在运行的开发版，然后安装这个分支：
   ```sh
   sh mac-app/scripts/build-app.sh debug --install
   open "$HOME/Applications/be-nice Development.app"
   ```
2. 刷新服务列表（不刷新可能要注销重登才出现）：
   ```sh
   /System/Library/CoreServices/pbs -update
   ```
3. 要测“零权限”，开发版必须**没有**辅助功能权限。若已授权：系统设置 → 隐私与安全性 → 辅助功能 → 把 “be-nice Development” 的开关**关掉**（不要删除条目，测完再打开）。菜单栏图标菜单第一行应显示 “Clipboard mode — no Accessibility needed” 或 “Accessibility revoked — using clipboard mode”。
4. 系统设置 → 键盘 → 键盘快捷键… → 服务 → 文本：找到 “Rewrite with Be Nice (Dev)”，确认勾选，给它配一个快捷键（建议 ⌃⌥⌘R）。

记录模板（每格写 ✅ / ❌ / 现象）：

| App | 服务菜单里能看到 | 原地替换 | ⌘Z 撤回 | 格式/换行 | B ⌘V 粘贴 | B Undo 恢复剪贴板 |
|---|---|---|---|---|---|---|
| Slack 桌面版 | | | | | | |
| TextEdit | | | | | | |
| 浏览器文本框 | | | | | | |

## 1. Slack 桌面版（重点）

1. 打开一个你自己的私聊（DM 给自己最安全），输入合成草稿，**不要发送**。
2. ⌘A 选中草稿。
3. 菜单栏 Slack → 服务（Services）：有没有 “Rewrite with Be Nice (Dev)”？如果没有，右键选区看看有没有“服务”子菜单。
4. 点它（或按你配的快捷键）。鼠标旁应出现 “Rewriting…”。
5. 结果记录：
   - 选区被替换成改写结果，pill 显示 “Replaced — ⌘Z to undo” → **原地替换 ✅**。
   - pill 显示 Replaced 但输入框没变 → Slack 不接收服务写回 ❌（这时 A 在 Slack 不可用，走 B）。
   - 服务菜单里根本没有这一项 → Slack 不把选区提供给服务 ❌。
6. 如果替换成功：按 ⌘Z，看是否回到原草稿。
7. 草稿有两行（Shift+Return）时再试一次，看换行是否保留。
8. 再试 B：⌘A ⌘C → 按 ⌃⌥⌘Space → pill “Copied — press ⌘V” → ⌘A ⌘V，看是否换成改写结果。然后点 pill 的 Undo → pill 显示 “Restored” → 再 ⌘A ⌘V，应该回到原草稿。
9. 可能出现系统提示“允许 be-nice Development 粘贴…”：记下是否出现、点了什么。
10. 删除草稿。

## 2. TextEdit

1. 新建文档（格式 → 制作纯文本），输入合成草稿，⌘A。
2. TextEdit → 服务 → “Rewrite with Be Nice (Dev)”。预期：原地替换，⌘Z 能撤回。
3. 再按第 1 节第 8 步试一次 B。
4. 不保存，关闭文档。

## 3. 浏览器文本框

1. Safari 或 Chrome 打开 `data:text/html,<textarea rows=5 cols=60></textarea>`，输入合成草稿，⌘A。
2. 浏览器 → 服务 → “Rewrite with Be Nice (Dev)”。记录是否原地替换、⌘Z 是否撤回。（Chrome 和 Slack 同为 Chromium 内核，结果可互相印证。）
3. 再试一次 B。

## 4. 收尾

- 把辅助功能开关重新打开（如果第 0 步关过），菜单第一行回到 “Accessibility: Granted”，确认原来的一键流程仍正常。
- 把记录表贴回给协调者。
