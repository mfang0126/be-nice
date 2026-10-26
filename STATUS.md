# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-27 09:50 AEDT

## 阶段：S1 Slack 安全写回（私聊已跑通，未交付）

2026-10-27 09:46 在真实 Slack 私聊（自己）中由 be-nice 完整走通：Rewrite → 三张卡片 → 替换 → 独立读回 → 撤销精确恢复，未发送消息（替换由 LCU 点击，撤销由用户点击，读回均经 LCU AX 确认）。

已解决的 S0 卡点：
- 会话身份：替换/撤销前复核同一进程、同一输入框元素、原文未变、窗口标题未变（`Ming Fang (DM) - mingfang.tech - Slack`）。同名会话无法区分（已知限制）。
- 入口不出现：输入框在 AXWebArea 下 10 层，祖先遍历从 8 层放宽到 16 层。
- 替换报 focusChanged：Slack 关窗后把焦点还给网页而非输入框；复核通过后对原输入框元素设 AXFocused，写入后也把焦点留在输入框。

仍未解决：
1. **富内容**：emoji 是 AXImage 子元素，不在 AXValue 里；尚未检测，含富内容的草稿可能被整篇替换丢失格式。下一项必须做（PLAN 要求无法保真时只给复制）。
2. 界面文案改英文（进行中）。
3. 同一会话内窗口标题变化（如未读标记）会误拒绝替换，偏安全，待实测观察。
4. 中文 IME、长文、频道和线程（S3）未测。

## 代码现状

- 改写窗口：设计 B「并排对比」，Slack 配色（入口茄子紫、替换绿、选中蓝）；“想怎么改”输入框已留位置（隐藏）。
- 入口按钮贴 Slack 输入区盒子右上角外侧；状态胶囊同一行左对齐，32 pt 同高。
- 安全写回核心 `WriteBack.swift`；Slack 已加入两份允许列表。
- 开发版 API key 读 `~/Library/Application Support/be-nice/dev-api-key`（0600，仅 DEBUG 编译），避免每次重编译弹 Keychain 密码；正式版只用 Keychain。
- 个人风格学习代码保留但不在 UI；旧小绿点卡片、多 App 探针已删除（标签 `archive/multi-app-m0-m2`）。

## 开发环境

- 开发版固定路径 `~/Applications/be-nice Development.app`，Bundle ID `com.benice.menubar.development`，本地签名证书指纹 `D933388477455C8C62344293E483E625F4B7B194`（不得重新生成）。
- 10-26 00:03 用户已授予 Accessibility；10-27 00:30 重建安装新版（并排对比窗口）后，运行中的 App 报告 `accessibilityTrusted: true`，**重建后授权保留已验证**。使用前跑 `python3 -I mac-app/scripts/debug-status.py`（0=已授权，2=未授权，1=无法确认）。
- 开发版模型配置：DeepInfra `https://api.deepinfra.com/v1/openai` + `deepseek-ai/DeepSeek-V4.1-Flash`，密钥取自 `~/.hermes/.env`。丢失时运行 `sh mac-app/scripts/configure-dev-model.sh` 恢复（用户 10-27 指定为默认）。测试不得用别的值覆盖。

## 下一步

1. 界面英文化（Sonnet 进行中）。
2. 富内容检测：输入框含 AXImage 等非纯文本子元素时，只允许复制不允许替换。
3. 中文/英文普通草稿多跑几次私聊闭环，再进入频道与线程（S3）。
