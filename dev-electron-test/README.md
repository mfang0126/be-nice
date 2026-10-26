# dev-electron-test（一次性测试靶，不是产品）

给 be-nice 的 M0 AX 写回探针提供一个**本地、离线、确定性**的 Electron 测试目标（模拟 Slack/VS Code 这类 Electron 应用），含三类控件：input[type=text]、textarea、contenteditable。

```
npm install
npm start          # 弹出测试窗口
```

以下为上一会话记录的手测观察（macOS 26.6.2 / Electron 33.4.11）；未附逐次调用、读回日志或时间戳，**尚未由 Swift 探针复现，不是当前支持承诺**。2026-10-23 本轮目标发现受阻，见 [运行记录](../docs/research/m0-runtime-2026-10-23.md) 与 `PLAN.md` 支持矩阵。

2026-10-24 新实测：AXValue 写入即时读回可能仍为旧值，随后才生效。增加有界等待后，三控件整值写入/恢复、范围设置/恢复均通过；AXSelectedText 三控件在 500ms 内未确认，保守报 FAIL，不能断言永久无效。旧探针曾因即时读回误报 FAKE_SUCCESS 并漏恢复。每个控件使用全新进程、唯一 fixture 和普通键盘正向对照后，AXValue 写入再执行单次 Cmd-Z 均未恢复原文；产品不能依赖该靶的原生撤销，必须自己保留并安全恢复原文。详见 [新运行记录与结构化证据](../docs/research/m0-runtime-2026-10-24.md)。

上一会话记录：
- ✅ 读 value：input / textarea / contenteditable 全部可读。
- ✅ 整体写 value（AXValue set）：三类控件全部成功，内容真的变了。
- ✅ 选区写（AXSelectedText set，选区为空）：静默无效，无报错——**假成功，必须读回验证**。
- ✅ 设置 AXSelectedTextRange：静默无效。

上述历史“范围设置静默无效”已被 10-24 实测推翻；历史“假成功”不能排除异步生效。当前结论仅采用 10-24 记录：整体写与范围设置/恢复通过，SelectedText 500ms 内未确认。不能将 Electron 对照靶结果外推为 Slack 或 VS Code 已支持。
