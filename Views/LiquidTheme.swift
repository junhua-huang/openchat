import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

enum Palette {
    static let accent = adaptive(0x5261D8, 0xA9B2FF)
    static let action = adaptive(0x4D5CCB, 0xBEC5FF)
    static let onAction = adaptive(0xFFFFFF, 0x19204F)
    static let paper = adaptive(0xF4F5FA, 0x0D101C)
    static let card = adaptive(0xFFFFFF, 0x1B2030)
    static let userBubble = adaptive(0xE7EAFE, 0x292F55)
    static let lilac = adaptive(0xCFD2FA, 0x303C78)
    static let aqua = adaptive(0xD3EDEB, 0x163C4A)
    static let peach = adaptive(0xF3DDD7, 0x483147)

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.paper
                if !reduceTransparency {
                    Ellipse().fill(Palette.lilac.opacity(0.65))
                        .frame(width: geometry.size.width * 1.2, height: 350)
                        .blur(radius: 80).offset(x: drift ? -90 : -35, y: -geometry.size.height * 0.25)
                    Circle().fill(Palette.aqua.opacity(0.50)).frame(width: 250, height: 250)
                        .blur(radius: 70).offset(x: geometry.size.width * 0.38, y: drift ? 80 : 130)
                    Circle().fill(Palette.peach.opacity(0.40)).frame(width: 240, height: 240)
                        .blur(radius: 70).offset(x: -geometry.size.width * 0.32, y: geometry.size.height * 0.39)
                }
            }
            .onAppear { drift = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduced in drift = !reduced }
            .animation(reduceMotion ? nil : .easeInOut(duration: 14).repeatForever(autoreverses: true), value: drift)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
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
    func liquidSurface(radius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(LiquidSurface(radius: radius, interactive: interactive))
    }
}

struct LiquidCluster<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 18) { content } }
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
