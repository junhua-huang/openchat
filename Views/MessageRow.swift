import SwiftUI
import UIKit

struct MessageRow: View, Equatable {
    let message: ChatMessage
    var fileVault: FileVault? = nil
    let canRetry: Bool
    var waitingForApproval = false
    var waitingForForeground = false
    let retry: () -> Void
    let edit: () -> Void
    let chooseVersion: (Int) -> Void
    @State private var copied = false
    @State private var copiedDiagnostic = false
    @State private var linkedFile: AttachmentPreview?
    @State private var missingFile = false
    @State private var showingTools = false
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.canRetry == rhs.canRetry && lhs.fileVault?.directory == rhs.fileVault?.directory &&
        lhs.waitingForApproval == rhs.waitingForApproval && lhs.waitingForForeground == rhs.waitingForForeground
    }
    private var progress: ReplyProgress {
        ReplyProgress.current(approval: waitingForApproval, paused: waitingForForeground,
            runningTool: message.toolActivities?.last(where: { $0.state == "running" })?.name, hasText: !message.text.isEmpty)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 12) {
                if message.role == .user {
                    if !message.text.isEmpty { Text(message.text).textSelection(.enabled).lineSpacing(5) }
                } else {
                    ForEach(message.timeline) { part in
                        switch part.content {
                        case .text(let text): RichMessageView(text: text).equatable()
                        case .tool(let activity): ToolActivityRow(activity: activity)
                        }
                    }
                }
                if message.role == .assistant, message.status == .complete, message.text.isEmpty, (message.attachments ?? []).isEmpty {
                    Text("模型没有返回文字，可以重新生成。").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(message.attachments ?? []) { file in
                    AttachmentCard(file: file, url: try? fileVault?.exportURL(file))
                    if let note = file.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }
                if let tools = message.toolActivities, !tools.isEmpty {
                    Button { showingTools = true } label: {
                        Label("工具记录（\(tools.count)）", systemImage: "wrench.and.screwdriver")
                            .font(.caption).padding(.vertical, 6)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("chat.tool-record")
                }
                if message.status == .streaming {
                    HStack(spacing: 9) {
                        if progress == .approval { Image(systemName: "hand.raised") }
                        else if progress == .paused { Image(systemName: "pause.circle") }
                        else { ProgressView().controlSize(.small) }
                        Text(progress.title).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).accessibilityLabel(progress.title)
                }
                if let problem = message.problem {
                    Label(problem, systemImage: message.status == .cancelled ? "pause.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let diagnostic = message.diagnostic {
                        Button {
                            UIPasteboard.general.string = diagnostic; copiedDiagnostic = true; TouchFeedback.tap()
                        } label: {
                            Label(copiedDiagnostic ? "已复制诊断信息" : "复制诊断信息", systemImage: copiedDiagnostic ? "checkmark" : "doc.on.doc")
                        }.font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                }
                if message.role == .assistant, message.status != .streaming { actions }
            }
            .padding(message.role == .user ? 16 : 0)
            .background(message.role == .user ? Palette.userBubble : .clear,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contextMenu {
                if !message.text.isEmpty {
                    Button("复制", systemImage: "doc.on.doc") { copy() }
                    ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
                }
                if message.role == .user { Button("编辑并重新发送", systemImage: "pencil") { edit() } }
                if canRetry { Button("重新生成", systemImage: "arrow.clockwise") { retry() } }
            }
            if message.role == .assistant { Spacer(minLength: 0) }
        }
        .onChange(of: message.text) { _, _ in copied = false; copiedDiagnostic = false }
        .onChange(of: message.diagnostic) { _, _ in copiedDiagnostic = false }
        .environment(\.openURL, OpenURLAction { url in
            guard ["sandbox", "file"].contains(url.scheme ?? "") else { return .systemAction }
            if url.scheme == "sandbox", let file = message.attachments?.first(where: { $0.name == url.lastPathComponent }),
               let local = try? fileVault?.exportURL(file), FileManager.default.fileExists(atPath: local.path) {
                linkedFile = AttachmentPreview(url: local)
            } else { missingFile = true }
            return .handled
        })
        .sheet(item: $linkedFile) { item in FilePreviewSheet(url: item.url) }
        .sheet(isPresented: $showingTools) {
            ToolRecordsView(activities: message.toolActivities ?? [])
        }
        .alert("没有对应的文件", isPresented: $missingFile) {
            Button("知道了", role: .cancel) { }
        } message: { Text("只有实际生成并保存的附件才能预览。请使用文件卡片，或让模型调用文件生成工具。") }
    }
    private var actions: some View {
        HStack(spacing: 2) {
            if !message.text.isEmpty {
                Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                    .accessibilityLabel(copied ? "已复制" : "复制回复")
                ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel("分享回复")
            }
            if canRetry {
                Button { TouchFeedback.tap(); retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("重新生成回复")
                if message.versionCount > 1 {
                    HStack(spacing: 0) {
                        Button { chooseVersion(message.activeVersion - 1) } label: {
                            Image(systemName: "chevron.left").frame(width: 44, height: 44)
                        }.disabled(message.activeVersion == 0).accessibilityLabel("上一版回复")
                        Text("\(message.activeVersion + 1) / \(message.versionCount)").font(.caption.monospacedDigit())
                        Button { chooseVersion(message.activeVersion + 1) } label: {
                            Image(systemName: "chevron.right").frame(width: 44, height: 44)
                        }.disabled(message.activeVersion + 1 >= message.versionCount).accessibilityLabel("下一版回复")
                    }.padding(.leading, 4)
                }
            }
        }.font(.system(size: 14)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.leading, -9)
    }
    private func copy() {
        UIPasteboard.general.string = message.text; TouchFeedback.tap(); copied = true
    }
}

struct RichMessageView: View, Equatable {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MessageContent.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose): inline(prose).lineSpacing(6)
                case .heading(let level, let text):
                    MathText(text, size: level == 1 ? 22 : level == 2 ? 20 : 17,
                             relativeTo: level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                        .font(headingFont(level)).fontWeight(.semibold)
                        .padding(.top, level < 3 ? 9 : 3)
                case .code(let language, let code): CodeBlockView(language: language, code: code)
                case .math(let expression): DisplayMathView(expression: expression)
                case .quote(let quote):
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
                        inline(quote).foregroundStyle(.secondary).lineSpacing(5).padding(.vertical, 3)
                    }.fixedSize(horizontal: false, vertical: true)
                case .divider: Divider().padding(.vertical, 5)
                case .listItem(let depth, let marker, let body, let checked):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        if let checked = checked {
                            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary).frame(width: 24)
                        } else { Text(marker).foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing) }
                        inline(body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(depth * 17))
                case .table(let headers, let alignment, let rows):
                    MarkdownTableView(headers: headers, alignment: alignment, rows: rows)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).tint(Palette.accent).textSelection(.enabled)
    }
    private func inline(_ value: String) -> MathText { MathText(value) }
    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title2; case 2: return .title3; default: return .headline }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let alignment: [TableAlignment]
    let rows: [[String]]
    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    Divider()
                    row(cells, header: false).background(index.isMultiple(of: 2) ? Palette.paper.opacity(0.7) : .clear)
                }
            }.background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.18)))
        }.textSelection(.enabled).accessibilityLabel("表格，可横向滚动")
    }
    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(headers.indices, id: \.self) { column in
                MathText(cells.indices.contains(column) ? cells[column] : "", size: 15, relativeTo: .subheadline)
                    .font(.subheadline).fontWeight(header ? .semibold : .regular).lineSpacing(4)
                    .frame(width: 142, alignment: cellAlignment(column)).padding(12)
            }
        }.background(header ? Palette.userBubble : .clear)
    }
    private func cellAlignment(_ index: Int) -> Alignment {
        guard alignment.indices.contains(index) else { return .leading }
        switch alignment[index] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
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
                    UIPasteboard.general.string = code; TouchFeedback.tap(); copied = true
                } label: { Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).accessibilityLabel("复制代码")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.45)
            ScrollView(.horizontal) {
                Text(code).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    .lineSpacing(4).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.14)))
            .onChange(of: code) { _, _ in copied = false }
    }
}
