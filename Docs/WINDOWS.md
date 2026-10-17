# Windows 上开发、云端编译、iPhone 真机测试

## 1. 先做一次无签名编译

你已有付费 Apple Developer 账号，不必先购买 Mac。本项目把 Xcode 编译安排在 GitHub 的云端 macOS runner 上；Windows 用于编辑代码、管理仓库和浏览 Apple 开发者网站。

1. 解压源码。
2. 在 GitHub 新建仓库，例如 `LiaoChat`。如果你计划按开放给开源项目的方式提供接入，实际发布的项目也应符合相应开源资格。
3. 仓库根目录应直接能看到 `App`、`Core`、`Views`、`Scripts`、`LiaoChat.xcodeproj` 与 `.github`。不要多套一层目录。
4. 在 Windows 文件管理器开启“隐藏的项目”，确认 `.github` 确实上传。用 Git 提交整个目录最稳妥；网页上传时要留意隐藏目录是否遗漏。
5. GitHub 仓库 → Actions → Build and test iOS → Run workflow。
6. 等待完成。绿色表示 Xcode 编译和项目中的 XCTest 在该 runner 上通过；有失败则打开失败步骤查看错误。

工作流会自动选择 runner 上可用的 iPhone 模拟器，无需在 Windows 安装 Xcode 或 iOS 模拟器。上传的 `simulator-build-and-tests` 产物供排查用，**不是 iPhone 安装包**。

0.2 液态玻璃版需要 Xcode 26+ 编译；工作流会从当前 macOS runner 已安装的 Xcode 中选择符合要求的版本。如果日志提示没有合适版本，需要换用提供 Xcode 26+ 的 GitHub macOS runner。最低运行目标仍为 iOS 17，旧系统自动使用磨砂材质。

如果使用 Git，在解压目录中运行：

```powershell
git init
git add .
git commit -m "Initial LiaoChat prototype"
git branch -M main
git remote add origin https://github.com/你的用户名/LiaoChat.git
git push -u origin main
```

命令中的地址换成你实际创建的仓库。这里没有替你创建或公开 GitHub 仓库。

## 2. 准备 Apple 的 App 身份

1. 打开 [Apple Developer 账户](https://developer.apple.com/account/)。
2. 在 Membership details 找到 Team ID，记下来。
3. 在 Certificates, Identifiers & Profiles → Identifiers 新建 App ID。
4. 使用自己的明确 Bundle ID，例如 `com.junhua.liaochat`；示例不是已经为你注册的 ID。此原型不要求额外开启 Sign in with Apple 能力。
5. 到 [App Store Connect](https://appstoreconnect.apple.com/) → 我的 App → 新建 App，选择同一个 Bundle ID。名称暂用“聊伴”，SKU 自定，例如 `liaochat-ios-001`。

此处的 **Sign in with ChatGPT** 和 Apple 的 **Sign in with Apple** 是不同功能。是否增加后者，应在正式上架时结合实际账户功能和审核要求决定。

## 3. 在 Windows 生成分发证书材料

需要可用的 OpenSSL。以下是通用 CSR／PKCS#12 生成命令，不要求 Mac。把这些文件保存在仓库之外的个人目录；不上传到聊天、不提交到 GitHub 源码。

在 PowerShell 中先检查：

```powershell
openssl version
```

如果找不到 OpenSSL，请先安装你信任来源的 OpenSSL 工具，或使用已经包含它的终端环境；然后执行：

```powershell
openssl genrsa -aes256 -out distribution.key 2048
openssl req -new -sha256 -key distribution.key -out distribution.csr
```

第一条会要求你设置保护私钥的密码。第二条交互填写你的邮箱、姓名／组织等信息，Common Name 可用 `LiaoChat Distribution`。不用加入额外 challenge password。

接着：

1. Apple Developer → Certificates → 新建 **Apple Distribution** 证书。
2. 上传刚生成的 `distribution.csr`。
3. 下载证书，保存为 `distribution.cer`。
4. 使用原来的私钥和刚下载的证书生成 `.p12`：

```powershell
openssl x509 -inform DER -in distribution.cer -out distribution.pem
openssl pkcs12 -export -inkey distribution.key -in distribution.pem -out distribution.p12
```

记住 PKCS#12 的 **Export Password**。它就是后面的 `P12_PASSWORD`，可能与你设置的私钥密码不同。`.p12` 需要同时包含证书和对应私钥，仅下载 `.cer` 不够。

如果团队已有有效分发证书和对应私钥，可以直接使用团队认可的材料，无需重复创建或撤销旧证书。

## 4. 创建分发描述文件

1. Apple Developer → Profiles → 新建。
2. 选择面向 App Store Connect 的 iOS 分发类型（界面也可能标为 App Store）。不要选 Development、Ad Hoc 或 Enterprise。
3. 选择上面相同的 App ID、Apple Distribution 证书。
4. 生成并下载 `.mobileprovision`，例如 `LiaoChat.mobileprovision`。

本指南通过 TestFlight 安装，不要求预先登记你 iPhone 的 UDID。

## 5. 配置 GitHub Variables 和 Secrets

GitHub 仓库 → Settings → Secrets and variables → Actions。

先在 **Variables** 添加：

| 名称 | 填什么 |
| --- | --- |
| `APP_BUNDLE_ID` | 你真正注册的 Bundle ID，例如 `com.junhua.liaochat` |
| `APPLE_TEAM_ID` | Apple 开发者 Team ID |

再在 **Secrets** 添加：

| 名称 | 填什么 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `distribution.p12` 文件的 Base64 |
| `P12_PASSWORD` | 创建 `.p12` 时输入的 Export Password |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision` 文件的 Base64 |
| `KEYCHAIN_PASSWORD` | 自定随机长密码，用于云端临时签名 Keychain |

PowerShell 把文件内容转 Base64 并复制到剪贴板：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\distribution.p12).Path)) | Set-Clipboard
```

粘贴到 `BUILD_CERTIFICATE_BASE64` 后，再复制描述文件：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\LiaoChat.mobileprovision).Path)) | Set-Clipboard
```

Base64 只是编码，保密方式仍然是 GitHub Secrets；不要把它放进普通 Variables。

## 6. 先导出一次设备安装包

仓库 → Actions → **Build for TestFlight** → Run workflow。

首次保持 **Upload to App Store Connect for TestFlight** 不勾选。工作流会检查描述文件的团队、Bundle ID、有效期、分发类型，然后归档与导出 `.ipa`。成功时可在 Artifacts 下载。

这是 App Store 分发包，不能把它当 Ad Hoc 包直接拖到手机。继续通过 TestFlight 分发。

## 7. 配置 App Store Connect API 密钥并上传

1. App Store Connect → Users and Access → Integrations → App Store Connect API。
2. 若尚未启用，使用有权限的账号申请／开启 API 访问。
3. 创建有上传构建权限的 Team API Key，并保存 Key ID、Issuer ID。按你账户当时提供的权限选项配置，只为所需 App 提供必要访问。
4. 下载 `.p8` 私钥。该文件通常只能下载一次，妥善保存。
5. GitHub Secrets 再添加：

| 名称 | 填什么 |
| --- | --- |
| `ASC_KEY_ID` | API Key 的 Key ID |
| `ASC_ISSUER_ID` | API Issuer ID |
| `ASC_PRIVATE_KEY_BASE64` | `.p8` 文件的 Base64 |

转换方式与上面的 `.p12` 相同：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\AuthKey_你的KeyID.p8).Path)) | Set-Clipboard
```

再运行 **Build for TestFlight**，这次勾选上传。它会上传到你的 App Store Connect，**不会替你提交 App Store 正式审核**。每次 workflow run／retry 会生成不同构建号。

上传后：

1. 到 App Store Connect → 你的 App → TestFlight，等待 Apple 处理完成。
2. 如果显示加密合规问答，按这个 App 的实际加密使用情况完成；工程没有替你自动回答。
3. 创建内部测试组，将拥有该 App 访问权限的自己的账号加入，并把构建加入测试组。
4. iPhone 安装 Apple 的 TestFlight，使用被邀请的 Apple 账号接收测试邀请并安装。
5. 按 [登录验收](AUTH-TEST.md) 测试。

Apple 处理和测试资格是后续平台步骤，CI 上传成功本身不等于 TestFlight 已可安装。对外邀请的测试流程也可能需要额外审核。

## 8. 以后怎么改代码

Windows 上用 VS Code 编辑 `.swift` 文件，提交后由云端编译。可以改 UI 文案、颜色、布局；添加 Swift 源文件后，生成脚本会自动收录 `App`、`Core`、`Views` 目录根部的 `.swift` 文件。

如需改 App 的展示名称，在 `App/Info.plist` 修改 `CFBundleDisplayName`。如果项目名称也改变，同步更新 `agent_name_hint` 为实际名称，并在所有安装实例保持一致。

`Scripts/generate_project.py` 每次会重新生成工程，长期修改编译配置应改生成脚本，避免只改 `.pbxproj` 后被下一次生成覆盖。

## 常见卡点

| 现象 | 先检查 |
| --- | --- |
| Actions 看不到工作流 | `.github/workflows` 是否位于仓库根目录；工作流是否在默认分支 |
| 缺少签名身份 | `.p12` 是否包含匹配私钥、密码是否正确、证书是否有效 |
| 描述文件不匹配 | Bundle ID、Team ID、所选分发证书和分发类型 |
| 无法上传 App Store Connect | 是否先创建 App 记录、API 密钥是否有访问权限、构建号是否重复 |
| 模拟器通过但手机登录失败 | 回环监听、Safari 回调、设备网络和账号授权；以真机结果为准 |
| 模型目录为空／403 | 套餐授权、工作空间策略、账户资格和可用模型 |

公开分享构建日志时，应先删除涉及授权地址、回调参数、证书、密钥或账户信息的内容。此工程没有主动输出 OAuth token 或完整授权 URL。
