# OpenChat · Liquid Glass

一个原生 SwiftUI AI 聊天 App：可连接自己的 ChatGPT 账户，也可使用 DeepSeek、OpenAI API 或其他 OpenAI 兼容服务商的 API Key。

## 2.0：工具、MCP 与真实文件

- 输入框“＋”导入照片、PDF、Word、Excel、ZIP 和常见文本；原生预览、图片缩略图、分享及保存到“文件”。
- 模型提出工具请求后执行并回传结果，支持分段读取当前对话附件、四则计算、读取指定网页、创建真实文件，以及打包已有附件。
- 添加 HTTPS MCP 服务器，获取工具目录；调用前确认工具和参数，显示执行状态，支持拒绝与停止等待。
- 本地生成 PDF、DOCX、XLSX、Markdown、CSV、JSON、HTML、SVG、ZIP 等；回复版本保留各自附件，虚构的 sandbox 链接不冒充下载。
- 官方 OpenAI API 的 Responses 连接可按需开启联网搜索、Python 和图片生成；云端工具默认关闭，费用和权限由服务商决定，不自动使用付费连接。
- 详细兼容范围、文件限制与使用方法见 [工具与文件指南](Docs/TOOLS-AND-FILES.md)。

## 1.0.1：模型推理强度

- 点击顶部模型 → “推理强度”，选择档位后点“完成”；聊天页模型下方显示当前选择。
- GPT-6.1 Sol / Astra 提供轻量、标准、深入、超高、最高；保留“默认”时不覆盖模型设置。其他已核实模型按其支持范围提供选项。
- 按对话和模型记住选择，新对话继承当前设置；发送和重新生成时固定本次强度，切换其他对话不会影响正在生成的请求。
- 支持 ChatGPT 连接及官方 OpenAI API；其他服务商、未知模型保持服务商默认，避免发送不兼容参数。详见 [推理强度说明](Docs/REASONING.md)。

## 1.0：围绕日常聊天重新打磨

- 更简洁的黑白灰液态玻璃导航；新建入口移至顶部，多行输入、发送后保留键盘、Command + Return 发送。
- 每段对话独立保存草稿，重开 App 恢复上次选择；兼容旧版聊天记录。
- App 内切换历史或新建对话时，其他对话可以继续生成；每段对话独立停止，保留已收到的文字。
- 流式文本以短间隔合并到界面；向上阅读时暂停跟随，并可回到最新回复。
- 编辑任意用户消息后创建新分支并重新发送，原对话及后续消息保留。
- 最后一条助手回复支持重新生成、保留旧版本及切换版本；继续追问时使用当前选中的回复。
- 标题、段落、嵌套列表、任务项、引用、分隔线、横向表格、围栏代码块；复制代码、复制回复、分享整段对话。
- 历史置顶、全文搜索、重命名、删除与生成进度；升级说明见 [1.0 更新记录](Docs/RELEASE-1.0.md)。

当前为 2.0.0 体验验证版。编译、82 项 XCTest 与原生界面截图以对应提交的 GitHub Actions 为准。首次登录及模型列表已在真机通过；真实推理恢复、API 计费和全部触控行为仍需设备验收，离线测试不能替代。详情见 [验证记录](Docs/VALIDATION.md)。

## 0.3.2：流式事件边界

- ChatGPT 与兼容 API 的 SSE 使用原始字节分行，保留空行边界；兼容 CR、LF、CRLF 和分散到多个字节的 UTF-8。
- 忽略空 data 心跳；分别报告无效 JSON、非对象事件与缺少类型，保留结构化错误码，不复制原始内容。
- 真机 0.3.1 返回 HTTP 200、缺失 Content-Type、invalid_event。云端已复现 Foundation 的 `.lines` 丢弃 SSE 空行（原本两条空行变为零条），使多条事件拼成非法 JSON；真实设备恢复仍需新版验收。

## 0.3.1：中性色与响应处理

- 界面改为黑白灰，去掉紫色、彩色光晕与背景动画，保留系统 Liquid Glass 控件。
- 根据响应体识别 SSE，兼容缺失或不准确的 Content-Type；保留 `response.completed` 完成校验。
- 识别普通或多行 JSON 错误与直接准入失败，提供按权限、用量和临时服务故障区分的提示。
- 错误回复可复制经过筛选的 HTTP 状态、响应格式、错误码、参数和 Request ID；不复制响应体、提示词、令牌或原始服务器消息。
- 请求与官方最小示例对齐，仅发送模型、文本上下文和必需的 `store:false`／`stream:true`。

真机已验证登录和模型列表。0.3.0 的推理在 MIME 检查处失败，截图无法确定实际返回内容；真实回复恢复仍需更新后真机复测，不能由离线测试替代。

## 0.3 版：多个 AI API 连接

- 无需 ChatGPT 登录即可进入 API 模式。
- 保存多个服务商的连接：名称、HTTPS 基础地址、API Key、一个或多个模型 ID。
- DeepSeek 与 OpenAI API 地址快捷填写；自定义地址保留服务商的版本路径。
- 获取模型列表或手动配置模型；不支持 `/models` 的服务仍可使用手动模型。
- Chat Completions SSE 流式回复、停止、重试；区分正常结束、长度截断、策略拦截与提前断流。
- Keychain 保存 API 连接与密钥，连接各自拥有独立的本机聊天记录。
- API 请求直接到你配置的地址，拒绝明文 HTTP、URL 内凭据与重定向；不使用开发者中转。

使用方法和兼容范围见 [API 连接指南](Docs/API-CONNECTIONS.md)。API 按服务商规则独立计费，与 ChatGPT 套餐授权分开。

## 基础功能与液态玻璃界面

- 原生液态玻璃导航与输入栏；iOS 26 及以上使用 `glassEffect`，较旧系统使用系统磨砂材质回退。
- 中文界面、跟随系统／浅色／深色外观、iPhone／iPad 自适应；适配降低透明度、增强对比度和减少动态效果。
- Continue with ChatGPT 登录；系统 Safari 组件配合本机 HTTP 回环监听。
- OAuth Authorization Code + PKCE；校验 state、nonce、JWT 签名、发行者、受众、有效期和账户身份。
- 按客户端注册分别保存账户与凭据；令牌进入设备 Keychain，支持续期、重新连接、切换与退出。
- 从当前账户获取模型列表；流式文字聊天、停止生成、失败后重新生成。
- 按连接分别保存本地聊天记录；新建、搜索标题与内容、切换、重命名与删除对话。
- Markdown 行内样式、可横向滚动的代码块、代码复制、回复复制与系统分享。
- 流式回复自动跟随；向上阅读后暂停跟随，并提供回到最新回复按钮。
- 触感反馈开关，以及模型选择、历史与账户设置面板。
- 没有开发者运营的推理中转服务器，没有内置共享 API Key。

2.0 已增加附件与工具；云端图片生成、Python 和搜索仅在所述 API 连接中按需开启。尚未提供语音或 ChatGPT 既有会话同步。Markdown 当前支持常见块排版与行内样式；尚未实现数学公式排版、完整 CommonMark 嵌套语义和代码语法高亮。

[打开界面设计参考](Design/liquid-glass-preview.html)。它含本地示例内容，不会连接账户或请求模型；其中界面是设计参考，不是真机运行结果。原生实现与验收项见 [液态玻璃设计说明](Docs/LIQUID-GLASS.md)。

## 从 Windows 开始

先阅读 [Windows 开发与真机测试指南](Docs/WINDOWS.md)。最短路径是：

1. 解压这个目录，在 GitHub 新建自己的源码仓库，将目录内容放到仓库根部。保留 `.github/workflows`。
2. 打开仓库的 **Actions → Build and test iOS → Run workflow**。先让云端 Mac 编译、运行测试。
3. 首次构建通过后，配置自己的 Bundle ID、Team ID、Apple Distribution 证书和 App Store Connect 描述文件。
4. 手动运行 **Build for TestFlight**；先不勾上传，检查归档导出。
5. 准备好 App Store Connect API 密钥后，再手动勾选上传，通过 TestFlight 在自己的 iPhone 安装验证。

**模拟器构建产物不能直接安装到 iPhone。** iPhone 需要设备版本、代码签名和合适的分发方式。云端构建服务是否收费，以你的 GitHub 账户与当时规则为准。

工程需要 **Xcode 26 或更新版本**编译，最低部署目标仍为 iOS 17.0。已有 Mac 时可打开 `LiaoChat.xcodeproj`，在 Signing & Capabilities 选择自己的 Team 并改 Bundle ID。云端工作流会自动挑选 runner 上已安装的 Xcode 26+；如果 runner 没有合适版本，会明确停止而不下载工具链。

## 登录的关键验证项

官方开源流程目前指定 `http://127.0.0.1:<port>/auth/callback`，并没有在所查文档中给出 iOS 专用接入保证。源码以 `SFSafariViewController` 保持应用内系统浏览器体验，以 `NWListener` 仅监听 `127.0.0.1`，等待三分钟并验证回调。首次登录与模型目录已在 iPhone 上通过；完整回复、续期、取消和后台恢复仍需验证。这不代表官方提供 iOS 专用支持或已获得上架批准。

请先在自己的 iPhone 上完成这四项：打开授权页 → 回环回调返回 → 身份验证通过 → 收到 `response.completed`。具体测试方法见 [登录验收](Docs/AUTH-TEST.md)。若回调一直失败，先解决平台兼容性或申请官方支持的客户端配置，不能直接把官方要求的回环地址改成自定义 scheme 来假装接通。

用户需要分别同意身份信息与套餐使用权限。拒绝套餐权限时，App 保留有效登录并提示重新授权，不发送模型请求。模型目录不等于调用成功，最终以一次完成的模型响应为准。

## 工程结构

| 路径 | 用途 |
| --- | --- |
| `App/` | App 入口、图标、Info.plist、隐私清单 |
| `Core/AuthManager.swift` | 账户、OAuth、续期、退出 |
| `Core/IdentityVerifier.swift` | OIDC 元数据与 RS256／ES256 验签 |
| `Core/LoopbackServer.swift` | 仅回环地址的本地回调监听 |
| `Core/ResponsesClient.swift` | 模型目录、Responses API、SSE |
| `Core/APIConnection.swift` | API 配置校验、多连接钥匙串存储与选择 |
| `Core/APIChatClient.swift` | 兼容 Chat Completions 的模型目录、请求与流式解码 |
| `Core/ChatStore.swift` | 聊天状态、账户隔离、本地持久化 |
| `Core/MessageContent.swift` | 流式 Markdown 围栏代码块拆分 |
| `Views/` | 液态玻璃主题、登录、聊天、历史、模型与账户设置 |
| `Tests/` | PKCE、编码、SSE、身份验签、流式代码块测试 |
| `Scripts/generate_project.py` | 仅用 Python 标准库重新生成 Xcode 工程 |
| `Scripts/select_xcode.py` | 为云端构建选择已安装的 Xcode 26+ |
| `Design/` | 可交互设计参考，包含本地示例消息 |
| `.github/workflows/` | 云端编译测试与手动 TestFlight 构建 |

## 开源与费用边界

这是按 OpenAI 所述开源／本地运行路径设计的项目。仓库中的 Apache 2.0 许可证只是软件许可证，实际使用仍受 OpenAI 接入资格与条款约束。开始提供付费功能、闭源产品或远程托管推理前，应先确认并申请对应接入资格。

用户授权的套餐调用与普通按量付费 API Key 是不同接入方式。不是“无限 API”，也不是为每个 App 增加一份独立 Plus 额度。套餐可用模型、额度、工作空间策略和预览限制由 OpenAI 决定。

## 官方参考

资料核对日期：2026-10-17。

- [Sign in with ChatGPT 快速开始](https://developers.openai.com/siwc/quickstart)
- [开源应用接入概览](https://developers.openai.com/siwc/token-sharing-open-source)
- [注册与登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [账户、续期与退出](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [预览限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [OIDC 元数据与 ID token 校验说明](https://developers.openai.com/siwc/website)
- [GitHub：在 macOS runner 中签名 Xcode App](https://docs.github.com/zh/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple：上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple：TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Apple：采用 Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple：自定义 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [DeepSeek：首次调用 API](https://api-docs.deepseek.com/zh-cn/)
- [OpenAI：Chat Completions 流式事件](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)

## 许可证

[Apache License 2.0](LICENSE)。项目中的测试 JWT 与公钥都是专用合成样本，不是真实 OpenAI 凭据。
