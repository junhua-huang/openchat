import Foundation
import Combine

@MainActor final class WorkingMemoryStore: ObservableObject {
    static let shared = WorkingMemoryStore()
    @Published private(set) var content = WorkingMemoryContent()
    @Published private(set) var ready = false
    @Published private(set) var problem: String?
    @Published private(set) var draft: WorkingMemoryDraft?
    @Published private(set) var draftProblem: String?
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
            loadDraft()
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
    private var draftURL: URL? { fileURL?.deletingLastPathComponent().appendingPathComponent("working-memory-draft.json") }
    func saveDraft(_ draft: WorkingMemoryDraft) throws {
        guard ready else { throw AppFailure.message(problem ?? "工作记忆尚未就绪。") }
        guard draft.text.count <= 32_000, draft.baseText.count <= 8000, draft.baseRevision >= 0 else {
            throw AppFailure.message("草稿过长，请精简后保存；当前编辑内容仍保留在页面中。")
        }
        if self.draft == draft { return }
        if !memoryOnly {
            guard let url = draftURL else { throw AppFailure.message("草稿保存位置不可用。") }
            try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtection])
        }
        self.draft = draft; draftProblem = nil
    }
    func discardDraft() throws {
        if !memoryOnly, let url = draftURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        draft = nil; draftProblem = nil
    }
    private func loadDraft() {
        guard let url = draftURL, FileManager.default.fileExists(atPath: url.path) else { draft = nil; draftProblem = nil; return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 500_000 else { throw WorkingMemoryContent.Failure.tooLong }
            let value = try JSONDecoder().decode(WorkingMemoryDraft.self, from: data)
            guard value.text.count <= 32_000, value.baseText.count <= 8000, value.baseRevision >= 0 else { throw WorkingMemoryContent.Failure.tooLong }
            draft = value; draftProblem = nil
        } catch { draft = nil; draftProblem = "未能读取编辑草稿，原文件已保留。已保存的记忆仍可使用。" }
    }
    private func persist(_ next: WorkingMemoryContent) throws {
        guard ready else { throw AppFailure.message(problem ?? "工作记忆尚未就绪。") }
        if !memoryOnly {
            guard let fileURL = fileURL else { throw AppFailure.message("工作记忆保存位置不可用。") }
            try JSONEncoder().encode(next).write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
        content = next; problem = nil
    }
}
