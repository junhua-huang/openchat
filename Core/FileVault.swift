import Foundation
import UniformTypeIdentifiers
import ImageIO
import Vision

struct FileVault: Sendable {
    let directory: URL
    init(accountID: UUID, root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LiaoChat/files", isDirectory: true)
        var folder = base.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values); directory = folder
    }
    static func safeName(_ name: String) -> String {
        let value = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && $0.value != 0x2028 && $0.value != 0x2029 && !"/\\:".unicodeScalars.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != ".." else { return "文件.txt" }
        // APFS limits filename bytes, not characters. Preserve the extension
        // and complete graphemes when shortening Chinese names or emoji.
        let ext = URL(fileURLWithPath: value).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 24 ? "." + ext : ""
        let stem = suffix.isEmpty ? value : String(value.dropLast(suffix.count))
        var result = ""; var bytes = 0
        for character in stem {
            let size = String(character).utf8.count
            if bytes + size + suffix.utf8.count > 220 { break }
            result.append(character); bytes += size
        }
        if result.isEmpty { result = "文件" }
        return result + suffix
    }
    func url(_ attachment: ChatAttachment) throws -> URL {
        guard attachment.storedName == URL(fileURLWithPath: attachment.storedName).lastPathComponent,
              attachment.storedName.hasPrefix(attachment.id.uuidString + "."), !attachment.storedName.contains("/") else {
            throw AppFailure.message("附件路径无效。")
        }
        return directory.appendingPathComponent(attachment.storedName)
    }
    func data(_ attachment: ChatAttachment) throws -> Data {
        let url = try url(attachment); let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw AppFailure.message("附件超过 10 MB。") }
        return try Data(contentsOf: url)
    }
    func exportURL(_ attachment: ChatAttachment) throws -> URL {
        let source = try url(attachment)
        guard FileManager.default.fileExists(atPath: source.path), Self.safeName(attachment.name) == attachment.name else {
            throw AppFailure.message("附件已不可用。")
        }
        let folder = directory.appendingPathComponent("exports", isDirectory: true).appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let target = folder.appendingPathComponent(attachment.name)
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.linkItem(at: source, to: target) }
            catch { try data(attachment).write(to: target, options: [.atomic, .completeFileProtection]) }
        }
        return target
    }
    func save(data: Data, name: String, mediaType: String? = nil, text: String? = nil, note: String? = nil) throws -> ChatAttachment {
        try Task.checkCancellation()
        guard data.count <= 10_000_000 else { throw AppFailure.message("单个附件最多 10 MB。") }
        let name = Self.safeName(name); let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let id = UUID(); let stored = id.uuidString + "." + (ext.isEmpty ? "bin" : ext)
        let value = ChatAttachment(id: id, name: name, storedName: stored, byteCount: data.count,
            mediaType: mediaType ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream", extractedText: text, note: note)
        try data.write(to: url(value), options: [.atomic, .completeFileProtection])
        do { try Task.checkCancellation() } catch { remove(value); throw error }
        return value
    }
    func saveImage(data: Data, name: String) throws -> ChatAttachment {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceGetType(source), let type = UTType(raw as String), type.conforms(to: .image),
              CGImageSourceGetCount(source) > 0 else { throw AppFailure.message("工具没有返回有效图片。") }
        let stem = URL(fileURLWithPath: FileVault.safeName(name)).deletingPathExtension().lastPathComponent
        return try save(data: data, name: stem + "." + (type.preferredFilenameExtension ?? "png"), mediaType: type.preferredMIMEType)
    }
    func importFile(_ source: URL) throws -> ChatAttachment {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw AppFailure.message("单个附件最多 10 MB。") }
        let data = try Data(contentsOf: source); let ext = source.pathExtension.lowercased()
        guard data.count <= 10_000_000 else { throw AppFailure.message("单个附件最多 10 MB。") }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image), ext != "svg" {
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw AppFailure.message("无法读取图片。")
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw AppFailure.message("无法转换图片。")
            }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AppFailure.message("图片转换失败。") }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            try? VNImageRequestHandler(cgImage: thumbnail).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            return try save(data: output as Data, name: source.deletingPathExtension().lastPathComponent + ".jpg", mediaType: "image/jpeg", text: text,
                            note: "图片将发送给当前模型；已缩放至最长边 2048 像素。")
        }
        let text = try FileFormats.extract(data, ext: ext)
        return try save(data: data, name: source.lastPathComponent, text: text,
            note: ext == "pdf" ? "提取可选择文字，不含扫描页、图片和版式。扫描件请另附图片。" : ["docx", "xlsx"].contains(ext) ? "提取正文、单元格文本、公式与缓存值；不重算公式，不含嵌入图表及版式。" : nil)
    }
    func remove(_ attachment: ChatAttachment) {
        if let url = try? url(attachment) { try? FileManager.default.removeItem(at: url) }
        let exported = directory.appendingPathComponent("exports", isDirectory: true).appendingPathComponent(attachment.id.uuidString)
        try? FileManager.default.removeItem(at: exported)
    }
}
