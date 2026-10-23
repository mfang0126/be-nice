# dev-electron-test（一次性测试靶，不是产品）

给 be-nice 的 M0 AX 写回探针提供一个**本地、离线、确定性**的 Electron 测试目标（模拟 Slack/VS Code 这类 Electron 应用），含三类控件：input[type=text]、textarea、contenteditable。

```
npm install
npm start          # 弹出测试窗口
```

2026-10-23 本机实测结果（macOS 26.6.2 / Electron 33.4.11）：
- ✅ 读 value：input / textarea / contenteditable 全部可读。
- ✅ 整体写 value（AXValue set）：三类控件全部成功，内容真的变了。
- ✅ 选区写（AXSelectedText set，选区为空）：静默无效，无报错——**假成功，必须读回验证**。
- ✅ 设置 AXSelectedTextRange：静默无效。

结论：Electron 控件整体替换可行；选区级写回不可靠，不要当作可依赖路径。
