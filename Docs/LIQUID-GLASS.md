# OpenChat：中性液态玻璃实现

这是原生 SwiftUI 实现。0.3.1 根据真机反馈改为黑白灰：日间使用近白底色，夜间使用近黑底色，按钮与消息气泡使用中性灰。去掉靛紫色、彩色光晕和背景动画，保留系统玻璃材质。

## 材质分层

- 顶部历史按钮、模型胶囊和账户按钮：`GlassEffectContainer` 中的独立原生玻璃形状。
- 底部新建按钮与输入栏：悬浮玻璃控件，输入栏和发送按钮保留独立触控区域。
- 消息正文：直接排版；用户气泡使用柔和填充，避免把长篇文字放在多层透明玻璃上。
- 历史、模型、账户：系统 sheet 与 NavigationStack，保留系统手势、搜索与关闭方式。

`Views/LiquidTheme.swift` 集中定义颜色、材质、背景与触感。`liquidSurface` 在 iOS 26+ 使用 `.glassEffect(.regular.interactive(...))`，旧系统使用 `.regularMaterial`。

## 可访问性

- 降低透明度开启时，玻璃控件换为实色背景。
- 背景保持静态；减少动态效果开启时，回到最新回复的滚动取消动画。
- 增强对比度时，兼容材质边界更明显；原生 Liquid Glass 跟随系统设置。
- 关键图标提供 VoiceOver 标签，主要图标触控区域为 48 点，发送操作包含在约 54 点高的输入控件中。
- 外观可跟随系统，也可单独选浅色或深色。

## 这次同时完善的行为

1. 发送前检查套餐授权、模型和存储状态。只有消息被接收后才清空输入框。
2. 阅读历史消息时暂停流式自动跟随，点击向下按钮可恢复跟随。
3. 历史支持按标题和消息内容搜索，按时间分组，可重命名与确认删除。
4. 新建对话会复用尚未输入消息的空对话，避免产生大量空记录。
5. 代码块可独立复制；输出未结束时，未闭合围栏也按代码块显示。
6. 账户设置面板关闭后再启动 OAuth 浏览器，避免两个 sheet 同时争抢展示。

## 验证范围

`Design/liquid-glass-preview.html` 是与上述视觉规则对应的设计参考，含示例对话和外观切换，不发出网络请求。设计参考渲染成功不等于 iOS App 已编译或真实玻璃材质已经真机验收。

编译必须使用 Xcode 26+，`#available(iOS 26.0, *)` 只负责运行时回退，不能让旧 SDK 认识新 API。云端工作流已加入工具链版本选择。

仍需在 iPhone 上核对：真实折射与控件融合、键盘遮挡、大字体、深色和增强对比度、横竖屏，以及真实登录与流式聊天。开源 OAuth 回环回调的首次登录和模型目录已真机通过；完整回复和会话续期仍需确认。

## Apple 官方参考

- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency
