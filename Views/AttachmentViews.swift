import SwiftUI
import QuickLook
import ImageIO

struct AttachmentPreview: Identifiable { let id = UUID(); let url: URL }

struct AttachmentCard: View {
    let file: ChatAttachment
    let url: URL?
    var remove: (() -> Void)? = nil
    @State private var preview: AttachmentPreview?
    @State private var thumbnail: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let url = url { preview = AttachmentPreview(url: url) }
            } label: {
                HStack(spacing: 12) {
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
                    } else { Image(systemName: file.isImage ? "photo" : "doc.text").font(.title3).frame(width: 24) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(url == nil ? "附件暂不可用" : ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.foregroundStyle(.primary).contentShape(Rectangle()).frame(minHeight: 48)
            }.buttonStyle(.plain).disabled(url == nil).accessibilityLabel("预览附件：" + file.name)
            if let remove = remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("移除附件：" + file.name)
            } else if let url = url {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("分享或保存文件：" + file.name)
            }
        }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.15)))
            .sheet(item: $preview) { item in FilePreviewSheet(url: item.url) }
            .task(id: file.id) {
                guard file.isImage, let url = url, url.isFileURL else { return }
                let image = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 144, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                if !Task.isCancelled, let image = image { thumbnail = UIImage(cgImage: image) }
            }
    }
}

struct FilePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NativeFilePreview(url: url).ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享或保存文件")
                    }
                }
        }
    }
}

struct NativeFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator; return view
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct ToolActivityRow: View {
    let activity: ToolActivity
    private var title: String { ToolPresentation.title(activity.name) }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if activity.state == "running" { ProgressView().controlSize(.mini) }
            else { Image(systemName: activity.state == "complete" ? "checkmark.circle" : activity.state == "cancelled" ? "pause.circle" : "exclamationmark.circle") }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium))
                if !activity.detail.isEmpty { Text(activity.detail).font(.caption2).lineLimit(3) }
                if let sources = activity.sources, !sources.isEmpty {
                    DisclosureGroup("查看来源（\(sources.count)）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sources) { source in
                                if let url = WebSearchClient.resultURL(source.url) {
                                    Link(destination: url) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(source.title).font(.caption).lineLimit(2)
                                            Text(url.host ?? source.url).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }.accessibilityLabel("打开来源：" + source.title)
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.caption).tint(Palette.accent)
                }
            }
        }.foregroundStyle(.secondary).accessibilityElement(children: .contain)
    }
}

struct ToolRecordsView: View {
    let activities: [ToolActivity]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(activities) { ToolActivityRow(activity: $0) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }.background(Palette.paper)
                .navigationTitle("工具记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ToolApprovalView: View {
    let approval: ToolApproval
    let decide: (Bool) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(approval.name, systemImage: "wrench.and.screwdriver").font(.headline)
                    Text("以下参数将发送给对应网站或 MCP 服务。允许一次只授权本次调用；拒绝后模型会收到拒绝结果。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(approval.arguments).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                }.padding(20)
            }.background(Palette.paper)
                .navigationTitle("确认工具调用").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button("拒绝", role: .cancel) { decide(false) }.frame(maxWidth: .infinity)
                        Button("允许一次") { decide(true) }.buttonStyle(.borderedProminent).tint(Palette.action)
                            .frame(maxWidth: .infinity)
                    }.padding(20).background(.regularMaterial)
                }
        }.interactiveDismissDisabled().presentationDetents([.medium, .large])
    }
}
