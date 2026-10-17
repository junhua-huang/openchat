# 交付验证记录

核对日期：2026-10-17。执行环境为 Linux，没有 Swift 编译器、Xcode、iOS SDK、Apple 签名材料或真实登录会话。

## 已执行并通过

| 检查 | 结果与边界 |
| --- | --- |
| Swift 源码语法树解析 | 全部 16 个 Swift 文件通过 tree-sitter Swift 语法检查；不代表 Swift 类型检查或 SDK 编译通过 |
| Xcode 工程格式 | OpenStep parser 可解析 `.pbxproj`；64 个工程对象的引用与源文件／资源路径有效 |
| 工程生成脚本 | Python 编译检查通过；重复生成得到同一工程内容 |
| 资源格式 | Info.plist、PrivacyInfo.xcprivacy、JSON 资源及共享 scheme XML 均可解析 |
| 工作流格式 | 两份 GitHub Actions YAML 可解析，触发器与 macOS job 存在；工作流本身尚未远程运行 |
| 签名／上传脚本 | `bash -n` 语法检查通过；没有执行实际签名或上传 |
| 测试数据 | 用独立 Python 密码库验证合成 RSA／EC 正常样本签名；PKCE 向量与 RFC 7636 一致 |
| HTML 设计参考 | Chromium 桌面与 390px 窄屏检查通过；浅深色切换、提示词填入、模型面板与本地预览提示正常，无 JavaScript 运行错误或横向溢出。此项只验证 HTML 设计参考，不代表原生 SwiftUI 界面已运行 |

## 已编写、尚未运行的 XCTest

`Tests/CoreTests.swift` 包含八个测试方法，覆盖：

1. PKCE S256 官方测试向量。
2. 带 Unicode 与保留字符的 form 编码。
3. SSE 注释、多行 data、空事件与结尾事件。
4. 只有 `response.completed` 且 `status=completed` 才成功；拒绝 incomplete／failed，不把 `[DONE]` 当成功。
5. 使用真实合成签名验证 RS256 与 ES256；拒绝错误 audience、issuer、nonce、过期、未来 iat、多 audience 缺 azp、篡改签名和 `alg=none`。
6. 缺少套餐权限时不启用推理。
7. 流式输出中未闭合的代码块、Unicode 内容。
8. 长围栏内的短围栏与 CRLF 换行。

这些测试在 `Build and test iOS` 工作流中执行。**本次没有执行 Swift XCTest，不能把测试源码存在当成测试已通过。**

## 尚需真实环境验证

- Xcode 类型检查、完整编译、链接与 XCTest。
- iOS 26+ 原生 Liquid Glass 和 iOS 17+ 回退材质；大字体、降低透明度和减少动态效果的真机表现。
- iPhone 上 Safari 与仅回环 NWListener 的互通；取消、超时、前后台切换。
- OpenAI 对实际账号和开源应用的接入资格、动态注册及授权。
- 真实 token 的签名算法／claims 兼容性与续期、退出撤销。
- 真实模型目录、流式响应、配额与工作空间策略。
- Apple 签名、归档、上传、TestFlight 安装与最终审核要求。

首个验证目标是 **在你的 iPhone 上完成一次真实登录和一次真实回复**。在此之前，这份交付应称为“源码原型”或“验证版”。
