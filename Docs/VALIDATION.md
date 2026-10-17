# 交付验证记录

## 1.0.1 推理强度验证

新增 8 项合成测试：Responses 与 Chat Completions 参数格式、默认省略字段、不兼容档位与服务商拒绝、每个请求独立捕获强度、生成中锁定选择、每段对话和模型恢复、重新生成／编辑分支保留旧版强度、旧数组存档与未来未知值兼容。总计 58 项，执行结果以本次 GitHub Actions 为准。Debug 合成界面增加模型与强度面板截图；不发起真实推理。真机仍需确认各档位实际调用及 TestFlight 更新。

核对日期：2026-10-18（北京时间）。本地执行环境为 Linux，没有 Xcode、iOS SDK、Apple 签名材料或真实登录会话。0.3.0 已在 GitHub macOS runner 通过 Xcode 编译与 18 项测试，并完成签名、上传和 TestFlight 安装。0.3.1 已通过云端编译与 30 项测试并成功上传。0.3.2 已通过 35 项云端测试。1.0.0 以对应提交 CI 为准。

真机反馈：ChatGPT 登录和模型目录成功；发送文字后在 Content-Type 检查处失败。尚未取得实际响应体和 MIME 值，因此根因未确认。0.3.1 的诊断为 HTTP 200、Content-Type missing、Body invalid_event。云端运行已验证 Foundation `.lines` 将合成流中的两条空行丢弃为零条；新字节读取保留两条。丢失分隔的夹具会出现相同事件 JSON 解析失败。真实设备恢复仍需复测。0.3.2 改用保留 SSE 空行的字节分行器，并细分失败形状。

## 已执行并通过

| 检查 | 结果与边界 |
| --- | --- |
| Swift 源码语法树解析 | 全部 29 个 Swift 文件通过 tree-sitter Swift 语法检查；不代表 Swift 类型检查或 SDK 编译通过 |
| Xcode 工程格式 | OpenStep parser 可解析 `.pbxproj`；90 个工程对象的引用与源文件／资源路径有效 |
| 工程生成脚本 | Python 编译检查通过；重复生成得到同一工程内容 |
| 资源格式 | Info.plist、PrivacyInfo.xcprivacy、JSON 资源及共享 scheme XML 均可解析 |
| 工作流格式 | 两份 GitHub Actions YAML 可解析，触发器与 macOS job 存在；0.3.1 的两份工作流已运行并成功 |
| 签名／上传脚本 | `bash -n` 语法检查通过；0.3.1 已在云端完成真实签名与上传；本地未持有签名材料 |
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

0.3.2 增加五个方法，覆盖原始字节管线、CR/LF/CRLF 空行、Unicode、分散的 UTF-8、多行 data、EOF、空 data 心跳、边界丢失复现及细分诊断。均使用合成流，不连接真实模型。

1.0 新增 15 项测试，覆盖 Markdown 语义、回复版本往返、编辑分支、旧存档迁移、损坏存档保护、停止与迟到数据隔离、跨对话生成、选中版本作为追问上下文，以及草稿／置顶／选择恢复。合成 transport 不访问模型服务。

全部 50 个方法由 `Build and test iOS` 执行。新增方法的执行结果需查看本次提交 CI；本地没有运行 Swift XCTest，不能把语法检查当成测试通过。

## 尚需真实环境验证

- 1.0.0 的 Xcode 类型检查、完整编译、链接与 XCTest，以本次提交 CI 为准。
- 真实 API Key 的模型目录、聊天、取消、计费与权限；钥匙串锁定／恢复；多个服务商切换与记录隔离的真机交互。
- iOS 26+ 原生 Liquid Glass 和 iOS 17+ 回退材质；大字体、降低透明度和减少动态效果的真机表现。
- 首次 iPhone 登录与模型目录已通过；取消、超时、续期与前后台切换仍需验证。
- OpenAI 对实际账号和开源应用的接入资格、动态注册及授权。
- 真实 token 的签名算法／claims 兼容性与续期、退出撤销。
- 真实模型目录、流式响应、配额与工作空间策略。
- 1.0.0 的签名、上传、TestFlight 更新和最终审核要求；0.3.0 的签名与安装已通过。

首个验证目标是 **在你的 iPhone 上完成一次真实登录和一次真实回复**。在此之前，这份交付应称为“源码原型”或“验证版”。

## 1.0 原生界面验证

Debug 专用合成夹具由 simulator 工作流启动并截取原生浅色、深色与空对话界面。夹具代码不进入 Release，不发起真实推理请求；截图仅用于内部 QA，以该提交的 native-ui-checks 产物为准。
