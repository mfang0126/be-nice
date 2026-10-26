# be-nice 当前交接入口

更新时间：2026-10-25 23:52 AEDT（开发中）。**PLAN.md 是唯一计划来源**；本文件只记录当前实现、证据和恢复步骤。

## 当前目标与状态（2026-10-25 21:53）

21:49 用户确认访谈共识，已写入 PLAN 的交付约定、S0–S4 和里程碑：先交付普通中英文整篇草稿的 Slack 私聊试用版，再验证频道和线程。三种内置方向保持原文语言与含义，个人风格学习后置。失效结果保留查看/复制并禁止替换；复杂内容无法保证保真时保留原稿、明确提示并提供复制。普通草稿必须无需终端或手动复制粘贴完成真实生成、编辑、替换和撤销，诊断通过不算交付。

**Slack 仍不可作为已适配产品使用。** S0 静态调查完成，见 [Slack S0 记录](docs/research/slack-s0-2026-10-25.md)：Slack 4.52.182；现有探针缺会话/线程上下文及富文本保真证据。限定编辑器范围、不输出正文的诊断已实现并独立 review，Swift6/脱敏/原子传输检查通过。最新签名诊断版本已于 21:34 安装到固定路径并启动；当时实际 Accessibility 为 false，尚无真实 Slack 诊断或读写证据。此状态不是实时查询结果，使用前以 debug-status.py 复核。

23:52 离线开发已完成：当前改写入口使用整篇草稿、不注入个人风格；生成后校验失效或 Apply 失败时保留候选和编辑内容，明确解释仅可编辑/复制并禁用按钮及键盘替换；显式复制使用当前编辑文本。独立 review 发现失败 Apply 后取消无法返回原 App，已修复为保留返回目标但清除写入事务，PID/bundle/前台检查不变，复查无高置信发现。

证据：实现 `task_46503539a8c1`、独立 review `task_2873a47a6a48`、修复 `task_1a789f83b411`、复查 `task_ef5d57a29f3f`（同一 Orca run）；本轮四个 worker 均已完成并释放。`RewriteCopyOnlyTests.swift` 隐藏窗口测试、`WriteBackTests.swift` 假访问器测试、`swift build --package-path mac-app` 通过；`python3 -I mac-app/OptimizerControllerTests.py` 的 8 个场景由修复者和独立 reviewer 验证通过。该 Python harness 提取生产 apply/cancel 方法并编译 inert doubles，仅证明窄范围回归，不证明真实焦点恢复、异步集成或 Slack 可用。新增复制按钮的真实布局/无障碍尚未检查；本轮未安装或启动新构建。

尚待实现/验证：Slack 目标身份与安全整篇写回、复杂内容识别与复制降级接线，以及真实私聊闭环。不要先开放 Slack allowlist，不再新增诊断宿主。具体前台测试时段尚未确定；此时只能推进不抢焦点的开发与隔离测试。原生 UI 用 LCU，浏览器用 Kimi WebBridge；不能操作已有草稿或发送消息。下文旧 M0/M1/M2 和跨 App 13 条矩阵均为历史证据，不是本轮待办。

## 开发签名与权限检查（最新）

- 固定安装路径：`~/Applications/be-nice Development.app`；Bundle ID `com.benice.menubar.development`。开发构建不再回退 ad-hoc。
- 本地代码签名证书已建立，私钥导入登录钥匙串，仅 codesign 访问、不可导出；证书指纹 `D933388477455C8C62344293E483E625F4B7B194`。持久证书位于 `~/Library/Application Support/be-nice/dev-signing/certificate.pem`，不得重新生成身份。
- `sh mac-app/scripts/build-app.sh debug --install` 构建安装；先正常停止当前开发 App。已实际构建、签名验证，并验证源码改变后 designated requirement 完全一致。
- `python3 -I mac-app/scripts/debug-status.py` 读取运行 App 的真实 AX 权限，校验 10 秒新鲜度、PID 和可执行路径；退出码 0=授权、2=未授权、1=无法确认。状态不含正文或凭据。
- 20:49 已完成无人值守检查入口 `sh mac-app/scripts/check-dev.sh [--runtime]`，57 个隔离诊断用例通过，独立 Sonnet review 无发现。实际 `--runtime` 结果：确定性检查通过，退出 2 / BLOCKED（尚未授权），不是产品测试失败。用法见 mac-app/README.md。
- 新身份实际状态仍为 `accessibilityTrusted: false`，首次授权后才能验证重建权限保留，不能把签名一致当成 TCC 验收通过。不再重置权限或反复打开模态文件选择器。
- 安全 shell 曾在转换临时 PEM 时创建敏感文件 checkpoint `2026-10-25T194944-b1c5f0ef`；已确认其中只有本次临时私钥，并定点删除该 checkpoint 和临时明文 PEM，未清理其他用户备份。


## 当前覆盖说明：Rewrite 改版进行中

以下 M1/M2 卡片与“最终二进制”描述为凌晨历史证据，不能用于当前改版验收。12:53 定案已改为屏幕边缘入口、居中遮罩、1–3 个完整风格候选、全文编辑与持续可见 Undo。`RewriteOptions.swift`、`ModelClient.rewriteOptions`、`RewriteWindowController.swift` 已实现；`WriteBack.prepare/validatePreparedTarget/apply(replacement:)` 保留原安全检查，`OptimizerController` 分离 pending 与 recovery，菜单提供撤销。

- 确定性回归见 `docs/research/rewrite-regression-2026-10-25.md`；最新 WriteBackTests 已再次通过。
- 原生固定文本窗口已验证候选全宽、点击展开、编辑、返回后草稿保留、Enter 重开、关闭正常退出。此为 UI harness，不是产品跨 App 写回验收。
- 取消遮罩后只在 be-nice 仍为前台时激活原 App，避免抢走用户已切换的 App；此改动待集成验证。
- Orca run `run_1e499df41b44`：边缘 Rewrite 按钮实现及独立 review 完成；最终 review 找到 Tab 聚焦第二候选后 Return 误开第一候选，修复任务 `task_7458cc467525` / `ctx_823986b226b7` 已完成，精确回归测试通过，worker 已释放。标题对齐断言已按 AppKit alignment inset 修正，并补右边界约束，UI tests 通过。13:22 最终键盘修复已重建、签名验证并启动。
- 13:20 已构建、ad-hoc 签名验证并启动新版；运行时明确显示 Accessibility: Revoked。必须由用户在系统设置重新授权当前 `.app`，此后再跑真实 Apply/Undo 与 13 条矩阵。专用 fixture 为 `/tmp/benice-rewrite-live-20261025-1320.txt`，已在 TextEdit 打开，未改其他文档。
- 待完成：最终键盘修复构建、真实 Apply/Undo 闭环与 13 条矩阵、长文/IME/无障碍、多屏/Space 验收。M2 盲评失败和 M3 未发布状态不变。
- 13:17 检查发现 App 已配置真实 DeepInfra endpoint/model；不要为 stub 测试覆盖现有用户配置或 Keychain。最新 demo 已正常退出。

## 1. 工作区与边界

- 当前 worktree：`/Users/mingfang/orca/workspaces/be-nice/be-nice-m0-axprobe`
- 分支：`mfang0126/be-nice-m0-axprobe`；基线提交：`4dc740f`。
- 所有代码、矩阵和证据均未提交，包含 tracked 修改和 untracked 新文件。以实时 `git status --short` 为准；新 clone/其他 worktree 不会自动获得这些改动。
- 不要回主 checkout `/Users/mingfang/Projects/be-nice` 工作；旧 `HANDOVER-CLAUDE-2026-10-23.md` 已过时。
- 禁止 `git reset/restore/stash/clean`。未获 commit/push/release 授权。
- 每个 feature 块完成后必须 spawn 独立 subagent review。真实写测试只用专用固定文本，不操作真实用户文档、消息或草稿。

## 2. 当前交付状态

### M0：可用目标的运行时矩阵已完成

- Swift `axprobe`、固定 fixture 门禁、有界读回、Terminal 排除、支持矩阵和结构化证据已完成。
- 菜单栏 LSUIElement 壳、Accessibility 首次引导/撤销状态、异步复查已实现并做过 GUI 冒烟。
- TextEdit、Notes：固定 ASCII 的 Value/SelectedText、恢复及各自单次原生 Cmd-Z 通过。
- Electron 33.4.11 测试靶：三控件 Value/范围通过；SelectedText 500ms 内未确认；AXValue 后单次原生 Cmd-Z 未恢复，含普通键盘正向对照。
- Safari/Chrome：页面内三控件 Value/范围通过；SelectedText 未确认。Safari contenteditable 不暴露 AXSelectedText。两者 undo 都没有有效正向对照，不作能力结论。
- Chrome contenteditable 另做了“页面只有一个控件”的隔离复测，排除与 textarea 的同角色混淆。
- VS Code 纯文本编辑器：Value/SelectedText setter 返回 success 但未观察到效果，不进入可写支持范围；未测集成终端。
- Slack 在标准路径/Spotlight 未找到，未形成支持或不支持结论。
- 所有结果只覆盖记录中的版本、固定 ASCII fixture 和控件，不外推 Unicode、IME、富文本、并发编辑或任意 App。

### M1：当前支持矩阵的真实端到端验收完成

- `SettingsWindow.swift`：base URL/model 持久化；API key 使用 Keychain，设置 UI 不回显 secret；慢 Keychain 读写离开主线程，保存期间锁定表单/关闭动作。
- `ModelClient.swift` + `CredentialStore.swift`：单一 OpenAI-compatible `/v1/chat/completions`，无 provider 特判、重试或 fallback。
- `TriggerController.swift`：浮层圆点、⌃⌥⌘Space、PID-scoped AXObserver、离主线程 AX 快照、定时位置刷新；浏览器仅允许 AXWebArea 内的文本控件，地址栏不显示。
- `WriteBack.swift`：idle/reading/requesting/validating/writing/verified/failed；目标身份和原文/选区复核；旧响应丢弃；取消实际请求；一次写入和有界读回；产品管理 Undo。
- 不确定/异常写入也保留 possible-write 恢复记录；Undo 只接受精确原文（已恢复）或精确应用值，第三值拒绝。选区 Undo 在写原文前先验证替换范围。
- `PreviewWindowController.swift` + `OptimizerController.swift`：preview-first，模型返回绝不自动应用；Apply/Undo 显式触发。`MenuBarShell.swift` 已接线并显示快捷键注册状态。
- 真实 TextEdit fixture 已分别通过快捷键选区、圆点整框；Notes 通过快捷键选区和整框；Safari、Chrome、专用 Electron fixture 均通过 input/textarea/contenteditable 整框。每条路径都完成 preview → 显式 Apply → 独立 AX 读回 → 显式 Undo → 精确恢复；Preview 不自动写入，完成流程中目标 App 保持前台。
- Chrome 使用 Kimi WebBridge 聚焦受管 fixture 并做最终 DOM 复核；Safari/Notes/Electron 使用 AX 焦点与动作，全程未再发送鼠标事件。Chrome disposable WebBridge session 已关闭，其他标签未动。
- 旧版两栏 Preview 布局已截图检查；运行时曾发现无共同 ancestor 约束异常并修复。当前已改为绿色圆点 + 输入框下方 440×230 圆角建议卡片，真实 UI 的 Apply/Undo/Dismiss 状态已操作验证，但新卡片尚未重跑 13 条 live AX 矩阵。Undo 可放弃时需显式确认，Apply/Undo 进行中禁止关闭或新触发。
- 支持策略保守：TextEdit/Notes 自动选区或整框；Safari/Chrome/专用 Electron fixture 仅整框；VS Code、Slack、真实第三方 Electron、Terminal、未知 App 均不支持。
- M2 功能链路已实现，但个性化盲评未通过；M3 Developer ID/公证/最低版本验收/公开发布尚未完成。当前不是公开 release。

### M2：单风格与紧凑卡片已实现，质量验收未通过

- 用户于 2026-10-25 明确收敛范围：**一个共享风格**，不做中/英 × 同事/客户四格，不做自动语言/对象识别；主交互是绿色圆点 → 下方紧凑建议卡片。PLAN.md 已同步。
- `StyleProfile.swift`：`StyleStore` 只持久化一个 `be-nice.style.guide`，不持久化原始样本。`StyleExtraction.swift` 严格要求单字段 `guide` JSON，拒绝 markdown、额外/缺失字段、空结果、超长和分隔符注入。
- `StyleWindow.swift` 已接入 Settings/App 和真实提炼 closure：粘贴样本 → Extract → 一个编辑框 → 显式 Save；Save/关闭清空样本，远程端点在发送前明示。真实 App 的 deterministic Extract/Save 和偏好读回通过。
- `ModelClient.swift` / `OptimizerController.swift`：复用同一个 completion 网络路径；风格是独立 user 消息，原文保持最后且不变。`/v1/openai` base path 不再重复拼接 `/v1`。DeepInfra key 只由临时 harness 从用户授权的 `~/.hermes/.env` 读取，未打印或写入 App/仓库。
- `PreviewWindowController.swift`：440×230 原生圆角卡片，单建议视图，Apply/Undo/Dismiss；`TriggerController.Target.anchorRect` 只用于下方定位，空间不足翻上方并限制在屏幕内。真实 AppKit UI 已截图并操作 Apply → Undo → Dismiss；这不是新的 live AX 写入验收。
- `StyleProfileTests`、`StyleExtractionTests`、`StyleWindowTests`、`PreviewTests` 和 stubbed `optimize()` 请求体测试已建立。DeepInfra `DeepSeek-V4.1-Flash` 真实合成样本请求完成，但最终独立盲评两案均选择通用版：个性化新增语气/致谢和语用强度，**M2 功能完成但质量验收未通过**。详见 `docs/research/m2-runtime-2026-10-25.md`。

## 3. 已执行验证

当前源码结果：

- `swift build --package-path mac-app`：2026-10-25 最终单风格/卡片及语义保真 prompt 源码通过。
- `ModelClientTests`、`SettingsTests`、`WriteBackTests`、`TriggerTests`、`StyleProfileTests`、`StyleExtractionTests`、`StyleWindowTests`、`PreviewTests`：最终源码全部通过；均不访问真实网络、真实 Keychain 或 live AX 写入。
- `axprobe selftest`、`benice --selftest`：最终源码通过。
- 两个独立 Swift 探针脚本分别 `swiftc -typecheck`、所有 11 个 `docs/research/m0-*.json` 解析、`Info.plist` 和 `git diff --check`：最终源码通过。不要把两个含 top-level code 的脚本放在同一次 `swiftc` 调用中。
- 2026-10-25 已重新执行 `sh mac-app/scripts/build-app.sh` 和 `codesign --verify --deep --strict`，最终 `.app` 包含单风格、卡片及最后的 prompt 改动。签名是 **ad-hoc**，不是 Developer ID，不代表公证；重建后 Accessibility/Keychain 授权仍需按最终二进制复核。
- M2 deterministic 测试偏好、fixture-only Keychain 项已清理；保留 Accessibility 历史状态。真实 DeepInfra key 从未写入 App 或仓库。
- M1 真实运行记录：`docs/research/m1-runtime-2026-10-24.md`。当前支持矩阵的 13 条产品闭环均通过，Preview 布局、accessory policy、ad-hoc codesign 通过；临时配置、Keychain 占位项、fixture、stub/server、测试 App 和临时驱动已清理并复核。

独立 review 已覆盖 M0 各证据块、菜单栏、模型/Keychain、设置、写回、触发和 M1 集成。M1/M2 review 提出的 Electron bundle 边界、风格 prompt 隔离、生产请求体覆盖和文档漂移已修复。单风格/卡片独立复审另发现端点变化后的隐私提示过期、空 Save 静默覆盖、`.stale` 永久加载三处问题，均已修复；最终小范围复审未发现这些修复引入新的 correctness/security 问题。`StyleWindowTests` 覆盖 local→remote 提示刷新和空 Save 保留；`.stale` 修复经源码复审、build 和全量回归验证，未做新的 live AX 运行。

## 4. 代码与证据入口

- `mac-app/Sources/axprobe/`：M0 CLI；`AXProbe.swift` 是探针，不是产品事务核心。
- `mac-app/Sources/benice/`：产品 App；`WriteBack.swift` 是安全写回核心，`OptimizerController.swift` 是主流程。
- `mac-app/*Tests.swift`：独立 deterministic selftest，不经 `swift test`。
- `mac-app/scripts/build-app.sh`：构建并 ad-hoc 签名 `.app`。
- `mac-app/partial-selection-check.swift [TextEdit|Notes|Code]`：专用局部 fixture；Notes 的“专用 note”只能由操作者保证，AX 窗口门禁不能证明 note 身份。
- `mac-app/electron-native-undo-check.swift`：Electron/Chrome 独立 undo 驱动；Chrome undo 仍无有效结论。
- `docs/research/m0-runtime-2026-10-24.md`：最新 M0 运行记录；同目录 JSON 是结构化观察摘要，不是完整 raw transcript。
- `docs/research/m1-runtime-2026-10-24.md`：M1 当前支持矩阵 13 条真实产品闭环、Preview 布局、运行异常与清理证据；这是目前的叙述性验收记录，不含逐流 JSON/截图归档。
- `docs/research/m2-runtime-2026-10-25.md`：单风格/卡片实现、deterministic App 流程、DeepInfra 真实合成请求、两轮盲评及质量未通过结论。
- `PLAN.md`：唯一计划和逐格支持矩阵。

## 5. 真实现场与清理状态

矩阵验证已经完成，没有待恢复的 GUI 写入现场。完整步骤、异常处理和逐项结果见 `docs/research/m1-runtime-2026-10-24.md`。

- 13 条闭环均以独立读回确认精确恢复：TextEdit 2、Notes 2、Safari 3、Chrome 3、专用 Electron 3。浏览器只测整框；Notes 覆盖选区与整框。
- 只使用本地确定性 stub、非真实占位 key 和专用固定文本；未调用外部模型，未写真实用户文档、消息或草稿。
- Chrome task session `be-nice-m1-matrix` 的唯一 managed tab 已关闭，focus emulation 已关闭，session-local `list_tabs` 为 0；Safari 只关闭精确匹配的 fixture tab，保留 Start Page；未关闭其他用户标签或文档。
- 专用 Notes note 已删除并确认位于 Recently Deleted；专用 Electron 和测试 `.app` 已停止并验证不存在；stub 与本地 HTTP server 已停止。
- 临时 base URL/model、Keychain 占位项、临时驱动、fixture 元数据和 stub 文件均已删除并验证。没有待 Apply 的 Preview 或恢复记录。
- LCU 0.12.1 已安装并注册到 Claude Code，`doctor` 可加载 Mac provider；当前 ChatGPT/CUA 组合不是 LCU 官方已测组合。需重连 Claude Code 后工具才加载，本轮 M1 证据没有使用 LCU。安装保留在 `~/.local/share/lcu/current/bin/lcu`。
- 当前若要重新运行，需重新创建本地 stub 和专用 fixture，再通过最终 `.app` 的 Settings 配置。不要复用真实凭据或现有文档。

ad-hoc 重建会改变 cdhash：Accessibility 必须对最终二进制授权，测试 Keychain 项也可能需要由同一最终二进制重新创建。不要用旧授权或旧占位项的成功来推断新二进制可用。

### M2 本轮清理

- 最终测试 `.app`、Preview harness 和 127.0.0.1:8877 deterministic stub 均已停止并复核；没有待 Apply 的建议或恢复记录。
- 测试 base URL/model、单风格及此前四风格偏好 key 已逐项删除，只保留 Accessibility 历史状态；当前会话创建的 fixture-only Keychain 项已删除并复核。
- 临时 harness、stub、请求日志、blind/mapping、测试二进制、截图和 Grammarly 抽帧目录已删除。用户 Hermes 配置、DeepInfra key 和原始录屏未修改或删除。

## 6. 常规恢复命令

```sh
pwd
git status --short
swift build --package-path mac-app
mac-app/.build/debug/axprobe selftest
mac-app/.build/debug/benice --selftest
swiftc -swift-version 6 -parse-as-library \
  mac-app/Sources/benice/WriteBack.swift mac-app/Sources/benice/ModelClient.swift \
  mac-app/WriteBackTests.swift -o /tmp/benice-writeback-tests
/tmp/benice-writeback-tests
sh mac-app/scripts/build-app.sh
codesign --verify --deep --strict mac-app/.build/be-nice.app
git diff --check
```

## 7. 下一步与限制

1. M1 的 13 条真实闭环是旧 Preview 的历史证据；若要把新卡片作为当前 M1 验收版本，需对最终 `.app` 重新授权 Accessibility，并重跑这 13 条 live AX 矩阵。
2. M2 单风格、模型接线、绿色圆点和紧凑卡片功能已完成，真实 DeepInfra 请求成功；但两轮最终盲评均偏好通用改写，个性化质量验收未通过。下一步应先调整质量策略/评估集，再重新盲评，不能把功能接通当作质量完成。
3. 公开首波还需 M3 发布必需项；Unicode/IME、全屏、多屏和真实第三方 Electron 等扩展验收不能冒充已完成。
4. 不为了 release 扩大支持矩阵，不承诺 Windows、Slack 自动抓取、自动替换或内嵌模型；不 commit、不 push、不 release，除非另行授权。

通用限制：固定 fixture 和身份复核不能消除 TOCTOU；单次 AX 调用可超过名义 500ms 观察窗口；剪贴板 changeCount 不变不是完整事务保护；全屏、多屏和真实第三方 Electron 仍需单独验收。Chrome 隔离复测后 WebBridge session 失去 tab 映射，可能存在一个无法程序化关闭的本地测试 orphan tab；不要关闭其他用户标签。`dev-electron-test` npm 曾报告 2 个 high severity dev 依赖漏洞，未擅自强制升级。
