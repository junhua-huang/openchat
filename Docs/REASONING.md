# 推理强度（1.0.1）

点击聊天页顶部模型按钮，在“模型与推理强度”面板中切换模型和强度，再点“完成”。模型按钮下方显示当前选择。强度对下一次发送、重新生成或编辑后创建的分支生效；正在生成时不可修改当前对话设置。

“默认”不发送强度参数，由服务商决定；它不代表自动选择更便宜的模型。更高强度通常需要更多时间和推理用量，不保证每个问题都回答得更好。

## 已核实的模型范围

以下为官方模型 ID 的精确匹配，核对日期 2026-10-17。列表来自当前账户或 API 连接，强度选项由已核实的兼容范围提供；不推测未知模型、日期快照或第三方别名的能力。

| 模型 ID | 可选强度（另有“默认”） |
| --- | --- |
| `gpt-6.1-sol`、`gpt-6-astra` | 轻量、标准、深入、超高、最高 |
| `gpt-6-sol`、`gpt-6-luna` | 关闭思考、轻量、标准、深入、超高、最高 |
| `gpt-5.2`、`gpt-5.4`、`gpt-5.5` | 关闭思考、轻量、标准、深入、超高 |
| `gpt-5.1` | 关闭思考、轻量、标准、深入 |
| `gpt-5` | 极低、轻量、标准、深入 |

## 请求和保存

- ChatGPT 套餐连接使用 Responses API 的 `reasoning: {"effort": "..."}`，保留 `store:false`、`stream:true` 和现有 SSE 完成校验。
- 官方 OpenAI API 连接（`https://api.openai.com/v1`）使用 Chat Completions 的 `reasoning_effort`。其他服务商仍可正常聊天，本版保持它们的默认强度，不假定名称相同就支持同一参数。
- 默认不发送上述字段；未知／不兼容档位在请求工厂处被拒绝，不发起网络请求，不自动重试为其他模型或付费服务。
- 设置随本机对话存档保存，每个模型独立记忆。新对话继承当前对话的设置；切换历史恢复该对话自己的选择，修改后立即保存。
- 每次请求在创建时固定模型和强度。每个回复版本保存当时的强度，换档重新生成不会改写旧版元数据。切换回复版本不改变下一次请求的选择。
- 旧存档没有设置时使用默认；未知的未来设置不会使整份存档无法读取。

本版不增加 Pro 执行模式、思考过程展示或用量计数。单元测试使用合成 transport 和请求体，不发起收费推理；最终生效、延迟和用量需在你有权限的账户上验证。

## 官方参考

- [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)
- [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [API deployment checklist](https://developers.openai.com/api/docs/guides/deployment-checklist)
- [GPT-5](https://developers.openai.com/api/docs/models/gpt-5)
- [GPT-5.1](https://developers.openai.com/api/docs/models/gpt-5.1)
- [GPT-5.2](https://developers.openai.com/api/docs/models/gpt-5.2)
- [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4)
- [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5)
- [ChatGPT 模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
