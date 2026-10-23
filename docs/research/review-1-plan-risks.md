# 评审1：计划文档技术风险评审
来源：subagent deleg_73b4e599 (gpt-6-astra, 2026-10-23)，6 次 API 调用，已联网查证。

## verdict
方向可行，但当前计划把"任意输入框可安全读写"误当成已解决前提；应先验证跨应用写回与防误覆盖，再做浮层，不能以按钮出现作为核心技术验收。

## critical_risks
- **P0 错误覆盖与跨应用误粘贴**：LLM 请求期间用户继续输入/移选区/切窗口/关文档。触发时必须保存 PID、窗口、元素、原文、选区；写回前重新校验。目标变化或无法验证时只展示结果，不自动切回旧应用或粘贴。第一次写回不确定时禁止盲目兜底，否则可能重复插入。
- **P0 "任意输入框"不是 AX 保证**：读取、定位、设定 Value、替换 SelectedText 是独立能力；AXUIElementIsAttributeSettable 和返回 success 都不等于真实内容已修改。Apple 列出 attributeUnsupported/cannotComplete/invalidUIElement；Terminal 不支持 SelectedText 写入，部分编辑器错误报告成功。必须建立按应用/编辑器/版本的支持矩阵。
- **P0 敏感数据与危险输入**：密码框、Secure Input、终端及代码执行界面不能进入通用自动重写路径。Terminal AX 文本可能是输出缓冲区而非可编辑命令；多行粘贴可能执行命令。默认排除终端、密码管理器和安全字段，提供应用禁用名单。
- **P1 剪贴板兜底不是可靠事务**：需保存多 item、多类型；恢复前比较 changeCount；过早恢复会让延迟粘贴读到旧内容；剪贴板管理器/跨设备同步可能已捕获临时文本。AX 写入、剪贴板粘贴、CGEvent 逐字输入分别需独立验证。
- **P1 浏览器/Electron 兼容需具体到控件**：Chromium AXValue 可写取决于 kSetValue 能力；WebKit contenteditable setValue 缺陷 173520 已 RESOLVED FIXED；但 WritingAssistant 仓库报告 Slack 可能返回替换成功而文字未变。
- **P1 nonactivating 浮层仍可能夺键盘焦点**：nonactivating 避免激活所属 app，但 Panel 仍可能成为 key。需显式禁 canBecomeKey/main，创建时定 styleMask，不用私有 API。
- **P1 Slack 语料外传与风格失真**：自动抓取增加登录态/页面变更/工作区政策风险，"只抓自己发言"仍可能含客户资料。MVP 只做手动粘贴、预览、脱敏；几段消息只能生成候选风格，需用户编辑确认+保留样本对比验证。

## assumption_errors（选摘）
- 仅识别 TextField/TextArea 不足以定义可编辑范围（自绘编辑器、网页嵌套节点、富文本容器可能不是这两个角色；同角色也不代表可写）。
- "输入框边界失败退到光标附近"不是可靠降级（光标矩形更难取）；最终降级应是固定菜单入口或快捷键。
- AXObserver 有进程边界：system-wide AX 对象不支持通知，需 NSWorkspace 监听前台切换、按 PID 建 observer。
- "永远在最前"不可作保证：nonactivatingPanel 不管 Space 归属和层级，需 collectionBehavior/level/全屏/Stage Manager 逐版本测试。
- AXIsProcessTrustedWithOptions 提示异步发生，不改变当前返回值；需处理授权后复查、运行中撤销、签名变化。
- "网页/API/本地模型提炼效果一样"无依据；prompt 拼接风格与原文缺指令隔离。

## missing_items（选摘）
- P0 写回状态机与恢复（idle→reading→requesting→validating→writing→verified/failed；每目标单请求，丢弃旧响应；空输出/截断/拒绝不能直接替换；恢复/撤销提前到 MVP）。
- P0 权限最小化与数据边界（仅用户触发时读取+调模型；API key 放 Keychain；本地模型失败不得擅自切远程）。
- P1 多显示器几何（统一 AX/CG/AppKit 坐标，负坐标、上下排列、points/pixels）。
- P1 IME 与文本语义（中文/日文未提交组合文字、emoji、UTF-16 选区索引、RTL、富文本、超长文本；marked text 跨应用难查询）。
- P1 发布与生命周期（最低 macOS 版本、稳定 bundle ID、Developer ID 签名+公证、LSUIElement/accessory、NSStatusItem 强引用、睡眠唤醒后 observer 重建）。
- P1 错误和性能（AXUIElementSetMessagingTimeout、受控队列、通知合并防抖、取消/超时/限流）。
- P1 可执行验收矩阵（TextEdit、Notes、Safari/Chrome input/textarea/contenteditable、Slack 桌面/网页、自绘编辑器；Terminal 和密码框验证被排除；验收重点是没有误写，不是 API 返回成功）。
- P1 风格质量约束（结构化可编辑风格配置，区分中/英、同事/客户；保留事实/数字/链接/姓名/否定/承诺强度；版本化 prompt 与风格）。
- P2 设置页与可访问性（权限状态、服务配置、隐私说明、暂停/禁用应用、失败后复制结果；圆点不能只靠颜色；快捷键是低成本可靠入口，不应排到"以后"）。

## suggested_milestone_order
M0＝最小菜单栏壳、权限状态、分发决策及**跨应用读写技术探针**（固定文本验证，不调 LLM）→ M1＝显式选区＋快捷键改写写回（原 M2 提前）→ M2＝手动粘贴 Slack 样本+可编辑风格+真实改写（原 M3-4 合并）→ M3＝浮层（原 M1，复用已验证读写核心）→ M4＝兼容性扩展、签名公证、发布验收。可参考开源 WritingAssistant（选区浮层与粘贴策略）、Selara（目标复核设计）；README 不是可靠性证明。

## evidence_urls
- https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue
- https://stackoverflow.com/questions/36263459/cocoa-accessibility-api-detect-if-setting-an-attribute-will-did-work-correctly
- https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/browser_accessibility_cocoa.mm
- https://bugs.webkit.org/show_bug.cgi?id=173520
- https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification
- https://developer.apple.com/fr/documentation/applicationservices/1459139-axobservergetrunloopsource
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout
- https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel.md
- https://philz.blog/nspanel-nonactivating-style-mask-flag/
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox.md
- https://developer.apple.com/forums/thread/805556
- https://developer.apple.com/library/archive/technotes/tn2150/_index.html
- https://github.com/Hiram31/WritingAssistant
- https://github.com/snowopsdev/selara
