import SwiftUI
import UIKit

struct MessageRow: View {
    let message: ChatMessage
    let canRetry: Bool
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 14) {
                if message.role == .assistant {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                        Text("OpenChat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    if message.role == .user { Text(message.text).textSelection(.enabled).lineSpacing(5) }
                    else { RichMessageView(text: message.text) }
                }
                if message.status == .streaming {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        if message.text.isEmpty { Text("正在思考…").font(.caption).foregroundStyle(.secondary) }
                    }.accessibilityLabel("正在回复")
                }
                if let problem = message.problem {
                    Label(problem, systemImage: message.status == .cancelled ? "pause.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if message.role == .assistant, message.status != .streaming {
                    HStack(spacing: 20) {
                        if !message.text.isEmpty {
                            Button { copy(message.text) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                                .accessibilityLabel(copied ? "已复制" : "复制回复")
                            ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享回复")
                        }
                        if canRetry, message.status == .failed || message.status == .cancelled {
                            Button { TouchFeedback.tap(); retry() } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                        }
                    }.font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
                }
            }
            .padding(message.role == .user ? 17 : 0)
            .background(message.role == .user ? Palette.userBubble : .clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contextMenu {
                if !message.text.isEmpty {
                    Button("复制", systemImage: "doc.on.doc") { copy(message.text) }
                    ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                }
            }
            if message.role == .assistant { Spacer(minLength: 0) }
        }
        .onChange(of: message.text) { _, _ in copied = false }
    }
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        TouchFeedback.tap()
        copied = true
    }
}

struct RichMessageView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(MessageContent.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text((try? AttributedString(markdown: prose,
                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose))
                        .textSelection(.enabled).lineSpacing(6).tint(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code): CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).lineLimit(1)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    TouchFeedback.tap()
                    copied = true
                } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).accessibilityLabel("复制代码")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.45)
            ScrollView(.horizontal) {
                Text(code).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Palette.card.opacity(0.80), in: RoundedRectangle(cornerRadius: 19))
            .onChange(of: code) { _, _ in copied = false }
    }
}
