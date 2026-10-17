# OpenChat · Liquid Glass

一个原生 SwiftUI AI 聊天 App 的开源源码原型：连接自己的 ChatGPT 账户，授权后通过官方 Responses API 使用符合条件的 ChatGPT 套餐额度。

**当前交付是源码验证版，不是已签名、已真机验收的安装包。** 本次环境没有 macOS、Xcode 或你的 Apple 签名材料；尚未运行 Xcode 编译、XCTest、真实 OAuth 登录和模型推理。Swift 语法解析与工程结构检查见 [验证记录](Docs/VALIDATION.md)。

## 0.2 版有什么

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

这版聚焦文字聊天；没有图片生成、语音、文件上传、联网工具或 ChatGPT 既有会话同步。Markdown 当前支持行内样式与围栏代码块，尚未实现表格、数学排版和代码语法高亮。

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

官方开源流程目前指定 `http://127.0.0.1:<port>/auth/callback`，并没有在所查文档中给出 iOS 专用接入保证。源码以 `SFSafariViewController` 保持应用内系统浏览器体验，以 `NWListener` 仅监听 `127.0.0.1`，等待三分钟并验证回调。**这是一条待真机验证的实现路径，不代表已经获得 iOS 支持或上架批准。**

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

## 许可证

[Apache License 2.0](LICENSE)。项目中的测试 JWT 与公钥都是专用合成样本，不是真实 OpenAI 凭据。
