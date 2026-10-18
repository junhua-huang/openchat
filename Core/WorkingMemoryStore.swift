import Foundation
import Combine

@MainActor final class WorkingMemoryStore: ObservableObject {
    static let shared = WorkingMemoryStore()
    @Published private(set) var content = WorkingMemoryContent()
    @Published private(set) var ready = false
    @Published private(set) var problem: String?
    private var fileURL: URL?
    private let memoryOnly: Bool

    init(directory: URL? = nil, memoryOnly: Bool = false) {
        self.memoryOnly = memoryOnly
        if memoryOnly { ready = true; return }
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LiaoChat/shared-memory", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var location = folder; try location.setResourceValues(excluded)
            fileURL = folder.appendingPathComponent("working-memory.json")
            reload()
        } catch { problem = "工作记忆存储暂不可用，请解锁设备后重试。" }
    }

    func reload() {
        guard let fileURL = fileURL else { return }
        do {
            let next: WorkingMemoryContent
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 100_000 else { throw WorkingMemoryContent.Failure.tooLong }
                next = try JSONDecoder().decode(WorkingMemoryContent.self, from: data)
                guard next.text.count <= 8000, next.revision >= 0 else { throw WorkingMemoryContent.Failure.tooLong }
            } else { next = WorkingMemoryContent() }
            content = next; ready = true; problem = nil
        } catch {
            ready = false; problem = "无法读取工作记忆，已保留原文件并暂停发送和写入记忆。"
        }
    }

    func replace(_ text: String, expectedRevision: Int) throws {
        try persist(content.replacing(text, expectedRevision: expectedRevision))
    }
    func setEnabled(_ enabled: Bool) throws {
        var next = content; next.enabled = enabled; next.revision += 1; next.updated = Date()
        try persist(next)
    }
    var context: String? { ready ? content.context : nil }
    private func persist(_ next: WorkingMemoryContent) throws {
        guard ready else { throw AppFailure.message(problem ?? "工作记忆尚未就绪。") }
        if !memoryOnly {
            guard let fileURL = fileURL else { throw AppFailure.message("工作记忆保存位置不可用。") }
            try JSONEncoder().encode(next).write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
        content = next; problem = nil
    }
}
