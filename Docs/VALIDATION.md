# 交付验证记录

核对日期：2026-10-18（北京时间）。本地执行环境为 Linux，没有 Xcode、iOS SDK、Apple 签名材料或真实登录会话。0.3.0 已在 GitHub macOS runner 通过 Xcode 编译与 18 项测试，并完成签名、上传和 TestFlight 安装。0.3.1 以对应提交的 CI 运行结果为准。

真机反馈：ChatGPT 登录和模型目录成功；发送文字后在 Content-Type 检查处失败。尚未取得实际响应体和 MIME 值，因此根因未确认。0.3.1 修复对 MIME 的过度依赖并增加安全诊断，真实聊天须更新后再次验证。

## 已执行并通过

| 检查 | 结果与边界 |
| --- | --- |
| Swift 源码语法树解析 | 全部 23 个 Swift 文件通过 tree-sitter Swift 语法检查；不代表 Swift 类型检查或 SDK 编译通过 |
| Xcode 工程格式 | OpenStep parser 可解析 `.pbxproj`；78 个工程对象的引用与源文件／资源路径有效 |
| 工程生成脚本 | Python 编译检查通过；重复生成得到同一工程内容 |
| 资源格式 | Info.plist、PrivacyInfo.xcprivacy、JSON 资源及共享 scheme XML 均可解析 |
| 工作流格式 | 两份 GitHub Actions YAML 可解析，触发器与 macOS job 存在；工作流本身尚未远程运行 |
| 签名／上传脚本 | `bash -n` 语法检查通过；没有执行实际签名或上传 |
| 测试数据 | 用独立 Python 密码库验证合成 RSA／EC 正常样本签名；PKCE 向量与 RFC 7636 一致 |
| HTML 设计参考 | Chromium 桌面与 390px 窄屏检查通过；浅深色切换、提示词填入、模型面板与本地预览提示正常，无 JavaScript 运行错误或横向溢出。此项只验证 HTML 设计参考，不代表原生 SwiftUI 界面已运行 |

## XCTest

`Tests/CoreTests.swift` 包含八个测试方法，已随 0.2 版在云端通过，覆盖：

1. PKCE S256 官方测试向量。
2. 带 Unicode 与保留字符的 form 编码。
3. SSE 注释、多行 data、空事件与结尾事件。
4. 只有 `response.completed` 且 `status=completed` 才成功；拒绝 incomplete／failed，不把 `[DONE]` 当成功。
5. 使用真实合成签名验证 RS256 与 ES256；拒绝错误 audience、issuer、nonce、过期、未来 iat、多 audience 缺 azp、篡改签名和 `alg=none`。
6. 缺少套餐权限时不启用推理。
7. 流式输出中未闭合的代码块、Unicode 内容。
8. 长围栏内的短围栏与 CRLF 换行。

0.3 新增 `Tests/APIClientTests.swift` 的十个方法，覆盖 HTTPS 地址与凭据校验、模型 ID 解析、Header 注入、端点与 Bearer Header、Unicode 上下文与中断消息排除、模型目录、流式正常完成、断流及服务商错误。样本密钥为合成值，不会调用真实服务商。

0.3.1 新增 `ResponsesWireTests.swift` 的十二个测试，覆盖最小推理请求、SSE 缺少或错误 MIME、多行 JSON 错误、HTML、空响应、JSON 完成事件、完成输出去重、中断流、诊断脱敏和旧聊天记录兼容。

全部 30 个方法由 `Build and test iOS` 执行。新增方法的执行结果需查看本次提交 CI；本地没有运行 Swift XCTest，不能把语法检查当成测试通过。

## 尚需真实环境验证

- 0.3.1 的 Xcode 类型检查、完整编译、链接与 XCTest，以本次提交 CI 为准。
- 真实 API Key 的模型目录、聊天、取消、计费与权限；钥匙串锁定／恢复；多个服务商切换与记录隔离的真机交互。
- iOS 26+ 原生 Liquid Glass 和 iOS 17+ 回退材质；大字体、降低透明度和减少动态效果的真机表现。
- 首次 iPhone 登录与模型目录已通过；取消、超时、续期与前后台切换仍需验证。
- OpenAI 对实际账号和开源应用的接入资格、动态注册及授权。
- 真实 token 的签名算法／claims 兼容性与续期、退出撤销。
- 真实模型目录、流式响应、配额与工作空间策略。
- 0.3.1 的签名、上传、TestFlight 更新和最终审核要求；0.3.0 的签名与安装已通过。

首个验证目标是 **在你的 iPhone 上完成一次真实登录和一次真实回复**。在此之前，这份交付应称为“源码原型”或“验证版”。
