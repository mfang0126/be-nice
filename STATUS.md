# be-nice 当前状态

> 每次更新**覆盖重写**，只写当前事实，不追加历史。历史见 git log 与 [docs/archive/](docs/archive/)。
> 更新：2026-10-28

## 阶段：v0.2.0 预览版发布准备完成，等用户批准发布

- PR #9–#14 已合入 main。
- 主回归 2026-10-28 00:00–00:02：6/6 PASS。证据：[docs/research/s3-slack-regression-2026-10-27.md](docs/research/s3-slack-regression-2026-10-27.md) 的 “Main regression 2026-10-27” 一节。

## 已修复并验证

- 语言与 `[tag]` 前缀保持（PR #9）：主回归用例 4（中文草稿）三张卡都是中文且保留 `[be-nice test]`。
- 富内容只给 Copy rewrite（PR #10）：链接、提及、列表；用例 5 通过，草稿未变。
- 线程输入框可用 Rewrite（PR #10）：用例 3 通过。
- 换行（PR #11）：Shift+Return 和空行草稿保留原结构；写入用 U+2028；结构读不到或对不上时只给 Copy rewrite（撤销在布局读不出时拒绝）。用例 2 通过。
- 允许列表只留 Slack（PR #11）：其他 App 不出入口。
- 状态胶囊跟随输入框（PR #13）：用例 6 通过。已知外观问题：胶囊会盖住消息列表最后一行的下沿。

## 仍未测

- 真中文 IME 组字、emoji、同名会话、窗口标题变化。
- 私聊（DM）只在今晚修复之前回归过；DM 与频道共用输入框代码路径。

## 下一步

用户批准 v0.2.0 发布（合并 PR、打 tag、发布 release）。
