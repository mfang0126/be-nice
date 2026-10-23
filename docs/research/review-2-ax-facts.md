# 评审2：AX/NSPanel 技术事实清单（deleg_4764e1fb，2026-10-23）

调研边界：本次验证的是官方文档、上游源码和开发者报告，没有在本机逐一执行 Safari、Chrome、Firefox、Slack、VS Code、Terminal.app 的写回测试。因此“已验证”指资料或源码已核对，不代表跨应用兼容性已实测。

---

AX 写回不能按应用名称简单判定支持与否。应针对具体元素和属性调用 AXUIElementIsAttributeSettable，并分别检查调用返回码与 settable 布尔值。Apple 列出的失败包括 AttributeUnsupported、InvalidUIElement、CannotComplete、NotImplemented；CannotComplete 可能是进程通信超时，不等于文本不可编辑。证据为官方搜索摘要。

---

NSPanel 的 nonactivatingPanel 只表示不激活所属应用，不表示不抢键盘焦点。非激活面板仍可成为 key window，接收键盘事件，而原应用继续拥有菜单栏。开发者通过复现工程和 WindowServer 行为分析验证了这种区分。

---

按钮浮层不抢键盘焦点的官方机制：设置 becomesKeyOnlyIfNeeded=true。Apple 明确说明，非激活面板只有在被点击

---

订阅实践：对目标应用创建 AXObserver，在应用元素上订阅 kAXFocusedUIElementChangedNotification，并将 AXObserverGetRunLoopSource 加入实际运行的 run loop。焦点变化后应检查新文本元素是否支持 kAXValueChangedNotification；不要未经验证就假定在应用根上注册 valueChanged 会可靠汇总所有子元素变化。多应用需分别管理 observer，切换应用可由 NSWorkspace 通知驱动。此为开发者实现证据与保守建议，非所有应用的通知保证。

---

Secure Input 的官方保证主要是阻止其他进程截获键盘事件。Apple TN2150 说明其用于保护密码等敏感输入，但该旧文档并未证明