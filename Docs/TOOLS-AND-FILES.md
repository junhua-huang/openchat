# 2.0 工具、MCP 与文件

## 在手机上使用

1. 输入框左下角“＋”可以选择照片或从“文件”导入。每条消息最多 4 个附件，每个不超过 10 MB；可直接发送附件，让模型分析。
2. 点击“＋ → 工具与 MCP”或右上角更多菜单，管理本次对话的工具。默认启用本地工具，云端收费工具默认关闭。
3. 请求“把这段内容生成 Word / PDF / Excel”等。支持工具的模型可以创建真实附件；点击卡片预览，使用分享按钮“存储到文件”或发给其他应用。
4. 模型需要读取网站或调用 MCP 时，聊天底部出现“等待确认”。打开后查看具体工具和参数，允许一次或拒绝。切换历史时，等待确认的对话显示手掌标记；停止生成会取消本机等待。

## 能力范围

| 功能 | ChatGPT 连接 | 官方 OpenAI API（Responses） | 其他兼容 API |
| --- | --- | --- | --- |
| 导入文本、PDF、DOCX、XLSX、ZIP | 本机解析后发送文字 | 本机解析后发送文字 | 本机解析后发送文字 |
| 图片理解 | 发送图片，取决于模型和账户支持 | 发送图片，取决于模型支持 | 需要兼容多模态消息格式 |
| 计算、读取附件、生成文件和打包 | 需要模型支持函数调用 | 支持函数调用的模型 | 需要服务商支持函数调用 |
| MCP 远程工具 | 手动添加服务器，逐次确认 | 手动添加服务器，逐次确认 | 手动添加服务器，逐次确认 |
| 读取指定 HTTPS 网页 | 每次确认，无登录信息 | 每次确认，无登录信息 | 每次确认，无登录信息 |
| 内置联网搜索、Python、图片生成 | 本版不发送这些云端工具 | 在工具设置中按需开启，服务商独立计费 | 不自动套用 OpenAI 的云端工具参数 |

API 连接可选择 Chat Completions 或 Responses。自动模式在官方 `api.openai.com` 使用 Responses，其他地址使用 Chat Completions。GPT-6.1 Sol / Astra 的工具调用需要 Responses。工具不支持时会保留已收到的内容并报告错误，不会偷偷换模型、改用另一份密钥或转到收费连接；也可在工具设置关闭工具，继续普通聊天。

## 文件处理与边界

- 常见文本和代码：UTF-8 / UTF-16；CSV、JSON、Markdown 等作为文字读取。
- PDF：读取可选择文字，最多 200 页；不识别扫描页和页内图片。扫描内容请另附图片。原文件仍可原生预览。
- DOCX：读取正文文字；不提取嵌入图片、图表和原始版式。不支持旧 `.doc` 二进制格式。
- XLSX：读取工作表的单元格文字、公式和已有缓存值；不重新计算公式，不解析图表。不支持旧 `.xls` 二进制格式。
- ZIP：可查看文件目录，不执行内容或把服务器路径解压到磁盘；本地生成可以打包文字文件，`zip_files` 也可打包当前对话已有图片和二进制文档。
- 文档提取最多 2 MB 文字；请求先附前 12000 字符并提供文件 ID，模型用 `read_file` 分段读取。单次读取最多 20000 字符。关闭工具时无法继续读取余文。
- 图片导入后转为 JPEG，最长边缩至 2048 像素，附可选的本机文字识别结果。视觉模型仍须支持图片；不能把文字识别当作完整图片理解。
- 本地 `create_file` 提供 TXT、Markdown、CSV、JSON、HTML、SVG、PDF、DOCX、XLSX 和 ZIP。Word/PDF 为基础正文排版；Excel 为单工作表二维数据，数字写为数值，字符串不会作为公式执行。原生工具不是完整 Office 编辑器。
- 单次生成正文最多 500 KB；单个文件及 ZIP 原始内容合计最多 10 MB。每问最多 8 轮、24 次本地或 MCP 工具执行。
- 图片生成返回的图片、Python 的文件引用，以及 MCP 的图片或内嵌资源 blob，只有成功取回并保存到本机后才出现附件卡片。MCP `resource_link` 仅返回资源地址，不会擅自附带凭据去下载。
- 模型文本中的 `sandbox:` 链接只有匹配当前回复真实附件时才可预览；虚构路径会明确提示没有对应文件。

## Python 文件分析与云端费用

Python、联网搜索和图片生成仅在官方 OpenAI API 的 Responses 连接中提供独立开关，默认关闭；并不包含在本机文件导入内。费用、模型支持和权限由你的 API 账户决定。

开启 Python 后，当前对话附件及本轮新建文件会上传至 OpenAI 文件服务并传给分析容器，最多 8 个不同文件。上传文件设置创建后 1 小时过期；容器本身按服务商的保留、计费和过期规则处理。App 使用原始文件，因此 Python 可以处理 PDF、表格和图片，而不只看到本机提取的节选。模型引用的生成文件在响应完成后下载至本机，避免只展示过期的容器链接。

## MCP 接入

在“工具与 MCP → 添加 MCP 服务器”填写名称、HTTPS MCP 端点和可选 Bearer Token。启用并保存时完成 `initialize`、`notifications/initialized` 和分页 `tools/list`；停用可以直接保存，不要求服务在线。

实现 Streamable HTTP 的 POST JSON / SSE 响应、请求 ID 校验、会话 ID 和协议版本 Header。工具通过 `tools/call` 调用，返回结果再交回模型。每个服务器最多 64 个工具，全部启用工具合计最多 100 个且定义不超过 250 KB。连接更改对下一次请求生效。

本版不启动 iPhone 本地 stdio 服务，不实现旧的 HTTP+SSE 双端点、OAuth 交互登录、sampling、elicitation、roots 或断流重放。需要这些能力的服务器会收到不支持提示。会话失效或断流不会自动重放可能产生副作用的调用；停止生成只保证取消 App 内等待及连接，不保证远程操作回滚。

## 存储与隔离

MCP 凭据保存在设备钥匙串，不进入模型工具定义、聊天 JSON 或日志。文件和聊天按 AI 连接 UUID 隔离，启用完整文件保护并排除系统备份。工具只能读取当前对话提供的附件 ID，不能指定任意本机路径。

草稿附件、回复文件、工具状态随会话保存；重新生成保留旧版本附件。编辑分支共享原附件引用，删除最后一处引用后才移除文件。取消或失败保留已完成的本机文件；旧版没有附件或工具字段的存档继续可读。

## 验证与参考

测试使用合成文件、模拟模型响应与 URLProtocol MCP 服务器，不发起付费推理，也不持有你的 API 密钥。真实 ChatGPT 工具权限、外部服务器、图片/容器服务和真机交互仍需更新后验收。

- [OpenAI Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [OpenAI File inputs](https://developers.openai.com/api/docs/guides/file-inputs)
- [OpenAI Code Interpreter](https://developers.openai.com/api/docs/guides/tools-code-interpreter)
- [OpenAI Image generation](https://developers.openai.com/api/docs/guides/tools-image-generation)
- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [MCP Lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)
