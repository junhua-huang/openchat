import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

enum Palette {
    // The global monochrome tint makes the dark-mode switch track white,
    // indistinguishable from its white thumb. Use UIKit's native switch color.
    static let switchTint = Color(uiColor: .systemGreen)
    static let accent = adaptive(0x242424, 0xEEEEEE)
    static let action = adaptive(0x171717, 0xEEEEEE)
    static let onAction = adaptive(0xFFFFFF, 0x151515)
    static let paper = adaptive(0xFAFAFA, 0x101010)
    static let card = adaptive(0xFFFFFF, 0x1C1C1C)
    static let userBubble = adaptive(0xECECEC, 0x292929)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct AmbientBackground: View {
    var body: some View {
        Palette.paper.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct LiquidSurface: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(border)
        } else {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(border)
                    .shadow(color: .black.opacity(0.06), radius: 18, y: 7)
            }
        }
    }
    private var border: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(.primary.opacity(contrast == .increased ? 0.25 : 0.08), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

extension View {
    @ViewBuilder func chatScrollEdgesHidden() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: [.top, .bottom]) }
        else { self }
    }

    func liquidSurface(radius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(LiquidSurface(radius: radius, interactive: interactive))
    }
}

struct LiquidCluster<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 6) { content } }
        else { content }
    }
}

struct LiquidIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 19, weight: .medium))
            .frame(width: 48, height: 48).foregroundStyle(.primary)
            .liquidSurface(radius: 24, interactive: true)
    }
}

struct OpenChatMark: View {
    var size: CGFloat = 64
    var body: some View {
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Palette.accent.gradient)
            .frame(width: size, height: size)
            .liquidSurface(radius: size * 0.32)
            .accessibilityHidden(true)
    }
}

@MainActor enum TouchFeedback {
    static func tap() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hapticFeedback") == nil || defaults.bool(forKey: "hapticFeedback") else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}
