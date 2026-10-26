# 评审3：本地小模型调研（deleg_6a833a52，2026-10-23，11 次 API 调用，275s）

## recommendation
主选 **Qwen3-1.7B Q4_K_M**（约 1.1GB），硬关闭 thinking（enable_thinking=False，模板层设置而非提示词）；嵌入式 **llama.cpp**（Apple Silicon 走 Metal，Intel Mac/Windows 走 CPU）。备选 Qwen2.5-1.5B-Instruct；质量升级档 Qwen3-4B-Instruct-2507；Qwen3.5-2B 列入挑战者实测。注意：目前不能承诺所有 8GB Intel Mac 数秒内完成。

## 关键证据
- **许可证**（开源分发必须过关）：
  - ✅ Apache-2.0：Qwen3-1.7B、Qwen3-4B-2507、Qwen2.5-1.5B、SmolLM2、SmolLM3、Gemma-4、Qwen3.5 —— 可商用、闭源集成、随 app 分发。
  - ⚠️ Qwen2.5-3B = Qwen Research License（非商用需另行申请）→ **排除打包**。
  - ⚠️ Llama-3.2 = Community License（需附协议、"Built with Llama"、月活门槛）。
  - ⚠️ Gemma-3 = 自定义条款（可商用但需传递使用限制）。
- **速度（社区 M1 16GB、llama.cpp、Q4_K_M、tg128 tok/s / peak RSS）**：
  Qwen3-0.6B 83.3/0.57GB；Qwen3-1.7B 43.4/1.31GB；Gemma-3-1B 42.0/0.85GB；Qwen3-4B 20.4/2.45GB；Llama-3.2-3B 27.0；Phi-4-mini 20.8；Qwen3.5-4B 14.1。
  → 一句话改写（输出 ~100 tokens）：Qwen3-1.7B 纯 decode ≈ 2.3 秒；4B 档 ≈ 5 秒。
- **改写质量直接证据**：SmolLM2 官方 OpenRewrite-Eval ROUGE-L 44.9，Qwen2.5-1.5B 46.9（不是满意率，不是事实保真率）。SmolLM2 官方示例显示即使提示"不新增信息"语气/篇幅仍会扩张——**防过度改写要靠产品约束（最小编辑、不新增事实、预览/差异、撤销），不能只换模型**。
- **中英文**：Qwen 系列中文最强；Llama-3.2 不支持中文；SmolLM2/3 偏英语；Phi-4-mini 英语为主。
- **引擎**：llama.cpp（MIT，C/C++ 可 Swift 桥接/XCFramework，跨平台）是首选；MLX Swift 可作 Apple Silicon 专用后端但首版不值得维护双后端；Ollama 适合原型但要管后台进程；LM Studio 桌面条款限制再分发，不可打包；ONNX GenAI / OpenVINO GenAI 留作 Windows 后期优化。

## open_questions（须在 M0/M1 补测）
1. 真实最小可用中文模型未定——0.5B/0.8B 快但可能保不住数字/否定/承诺；Qwen3-0.6B、Qwen3.5-0.8B 进低配实验组。
2. 必须补测真实目标机：M1 8GB、8GB Intel Mac、无独显中端 Windows；分别报冷加载、TTFT、完整输出 p50/p95、峰值内存与 swap。
3. 质量验收用中英混合短消息：金额、日期、姓名、否定、条件承诺、粗口、emoji、缩写、已通顺无需修改；加盲评。
4. 完全本地要覆盖整条链：推理、日志、崩溃报告、遥测、风格样本都不上传原文。
5. 许可证结论是工程筛选不替代法律审核；模型权重、量化、引擎、UI 许可证分别审查。

## 证据 URL（主选与关键基准）
- https://huggingface.co/Qwen/Qwen3-1.7B
- https://huggingface.co/unsloth/Qwen3-1.7B-GGUF
- https://huggingface.co/datasets/enescingoz/humaneval-apple-silicon
- https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
- https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct
- https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct
- https://github.com/ggml-org/llama.cpp
- https://github.com/ggml-org/llama.cpp/blob/master/build-xcframework.sh
- https://github.com/ml-explore/mlx-swift-lm
- https://docs.ollama.com/faq
- https://lmstudio.ai/app-terms
- https://onnxruntime.ai/docs/genai/
- https://github.com/openvinotoolkit/openvino.genai

完整 transcript：/Users/mingfang/.hermes/cache/delegation/live/deleg_6a833a52/task-0.log
