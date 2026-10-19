# Sign in with Apple

欢迎页和「账户与设置」提供 Apple 系统原生登录按钮，随系统语言和深浅色显示。登录可选；原有 ChatGPT/API 连接继续可用。Apple 登录确认的是 OpenChat 的本机身份，不代表获得 ChatGPT 套餐、API 密钥、云端聊天同步或账户服务器会话。

## 原生流程

- `ASAuthorizationAppleIDProvider` 请求姓名和邮箱，允许用户使用 Apple 私密转发地址。每次请求使用独立的安全随机 state 和 nonce；仅接受当前请求的一次回调。
- 通过固定的 `https://appleid.apple.com/auth/keys` 获取公钥，复用 JWT 验证器检查签名、issuer、当前 App bundle ID、过期时间和 nonce；核对 token subject 与系统返回的 user ID。不会信任仅解码的 JWT，也不会跟随 token 内的公钥地址。
- 仅将 user ID、姓名和邮箱写入单独的 Keychain 项，使用 `WhenUnlockedThisDeviceOnly`；不持久化 Apple identity token 或 authorization code。姓名和邮箱可能只在首次授权返回，同一用户再次登录时保留原字段，更换用户不继承旧身份资料。
- 启动及回到前台检查 credential state。revoked、notFound、transferred 清除本机身份；临时检查失败保留资料并提示重试，不误报为已确认登录。监听系统撤销通知并立即失效本机会话。
- 退出清除 Apple 的本机身份资料。不会更改 ChatGPT/API 凭据、聊天记录和共享记忆；Apple 身份字段不会注入模型请求。退出后如果 Apple 不再返回姓名，使用邮箱或「Apple 账户」作为名称。
- 本项目无 OpenChat 账户服务器，也没有申请或保存 Apple refresh/access token，因此没有服务端 token 交换或撤销。UI 明确告知如何在系统设置停止 Apple 授权。将来如加入账户服务器，必须在服务器验证授权、签发会话，并实现账户删除、token 撤销及服务器通知；不能把本机状态用作服务器鉴权。

## 发布配置

1. 在 Apple Developer 的 Identifiers 中打开 `com.junhuahuang.openchat`，启用 **Sign in with Apple**。
2. 重新生成该 App ID 的 **App Store Connect distribution provisioning profile**，下载并替换仓库 secret `BUILD_PROVISION_PROFILE_BASE64`。无需将 Apple 私钥或 client secret 放进 App。
3. 重新运行构建。`App/OpenChat.entitlements` 声明 `com.apple.developer.applesignin = [Default]`；项目生成器只为 App target 配置该权限。`signing-setup.sh` 在正式归档前检查描述文件，缺少权限时给出具体修复方法，不生成无法使用 Apple 登录的发布包。
4. PR 构建仅检查描述文件的能力，不安装签名材料、不打印描述文件内容；没有 secret 时标注未检查。unsigned archive 通过不等于签名或真实 Apple 登录通过。

原生 iOS 登录不需要网页 Service ID、网页回调域名或自建浏览器回调。

## 验证范围

`Scripts/check_apple_sign_in.swift` 在 macOS runner 上使用内存存储和合成身份，检查首次资料保留、账户隔离、随机参数、重复回调、错误 state/subject/token、用户取消、存储失败、撤销、离线状态检查，以及退出/重新登录后的旧异步结果。真实合成签名覆盖签名验证及错误 issuer、audience、nonce、过期、未来 iat 和篡改拒绝。

原有便携逻辑检查继续执行。另做 iOS Release archive 和回归测试代码编译；不启动 App，不调用真实 Apple 授权，不使用模拟器或物理 iOS 设备。系统授权弹窗和 Apple 登录联调未据此验证。

参考：

- [Apple：Implementing User Authentication with Sign in with Apple](https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple)
- [Apple：Get the most out of Sign in with Apple](https://developer.apple.com/videos/play/wwdc2020/10173/)
- [Apple：Handling account deletions and revoking tokens](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
