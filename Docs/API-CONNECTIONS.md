# 使用其他 AI 服务商的 API

0.3 版提供独立于 ChatGPT 登录的 API 模式。它支持 **OpenAI 兼容的 Chat Completions 文本流式接口**，使用 `Authorization: Bearer <API Key>`。

## 添加和使用

1. 首次打开 App，选择“使用其他 AI API”；已进入聊天时，打开右上角账户 → “API 连接与服务商”。
2. 点击“添加 API 连接”，填写连接名称、HTTPS 基础地址和自己的 API Key。
3. 模型 ID 可每行一个，也可用逗号分隔。点击“获取服务商模型列表”可读取 `/models`，再点选需要的文本模型；该操作不发送聊天。
4. 保存后，在连接列表点击“使用此连接”。顶部模型按钮会显示当前连接名，可切换模型。
5. 编辑连接可更新密钥、地址和模型，也可删除连接。ChatGPT 账户可以在账户设置中切换回来。

地址示例：

| 服务 | API 基础地址 |
| --- | --- |
| DeepSeek | `https://api.deepseek.com/v1` |
| OpenAI API | `https://api.openai.com/v1` |
| 其他兼容服务 | 服务商文档指定的完整基础路径，例如 `https://example.com/compatible-mode/v1` |

模型名与权限以你的服务商控制台为准。程序不会为你开户、购买额度或内置共享密钥。**API 费用由服务商单独计算，不扣减 ChatGPT Plus 套餐额度。**

## 接口范围

- `GET <base>/models`：解析 `{"data":[{"id":"model-id"}]}`。列表为空或接口不支持时可直接手动填写模型 ID。
- `POST <base>/chat/completions`：发送 `model`、`stream:true` 和本次对话中已完成的 `messages`。
- 读取 SSE 的 `choices[0].delta.content` 或 `refusal`。`finish_reason=stop` 视为完成；`length`、`content_filter` 和工具调用保留已有输出并标记未正常完成。
- 只返回 `[DONE]` 而不提供完成状态、非 SSE 或不兼容的 JSON 不会被误标为完整回复。
- 暂不支持 Anthropic 原生 Messages、Gemini 原生协议、Azure 的专用 API Key／版本参数、图片、音频、文件、工具调用或思考过程展示。有 OpenAI 兼容端点的服务可使用兼容地址。
- 部分兼容模型还要求额外参数，或不支持纯文本流式请求；本版不承诺所有被模型目录列出的模型都可聊天。

## 记录与密钥

API 配置与密钥存入 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 保护的独立 Keychain 项目，不写入聊天 JSON、UserDefaults、源码或日志。应用在设备锁定时不能读取它们。

每个 API 连接使用独立 UUID 保存本机对话；切换到不同连接不会自动携带上一连接的历史。编辑同一连接会保留其历史；如果要连接另一家服务，建议新建连接。发送消息时会把当前对话所需的上下文交给当前连接的服务商。

删除连接会从当前钥匙串数据中移除密钥，本机聊天文件保留；重新创建是新的连接，不会自动恢复旧记录。清空聊天记录可在该连接的账户设置中执行。删除本机密钥不会撤销服务商控制台中的密钥。

只接受不含 URL 用户名、密码、查询参数或 fragment 的 HTTPS 地址。API 客户端不跟随 HTTP 重定向，防止把凭据发送到跳转目标；应直接填写最终 API 基础地址。

## 验证

新增 XCTest 覆盖 URL 校验、头部注入、路径与 Bearer Header、Unicode 上下文、模型目录、SSE 完成与中断。测试使用合成 key 和离线数据，不会调用收费服务。真实服务商的请求、余额与权限仍需用你自己的密钥验收。

官方协议参考：

- https://api-docs.deepseek.com/zh-cn/
- https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
