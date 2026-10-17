import Foundation
import Combine

struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case complete, streaming, failed, cancelled }
    var id = UUID()
    let role: Role
    var text: String
    var status: Status = .complete
    var problem: String?
}

struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title = "新对话"
    var updated = Date()
    var model = ""
    var messages: [ChatMessage] = []
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var threads: [ChatThread] = []
    @Published var selectedID: UUID?
    @Published private(set) var models: [ModelChoice] = []
    @Published var selectedModel = ""
    @Published private(set) var isSending = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var storageReady = false
    @Published var errorText: String?
    private let accountID: UUID
    private let auth: AuthManager
    private var fileURL: URL?
    private var requestTask: Task<Void, Never>?
    private var generation: UUID?
    var selected: ChatThread? { threads.first { $0.id == selectedID } }

    init(accountID: UUID, auth: AuthManager) {
        self.accountID = accountID
        self.auth = auth
        do {
            var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("LiaoChat/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let url = directory.appendingPathComponent(accountID.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                threads = try JSONDecoder().decode([ChatThread].self, from: Data(contentsOf: url))
                for i in threads.indices {
                    for j in threads[i].messages.indices where threads[i].messages[j].status == .streaming {
                        threads[i].messages[j].status = .cancelled
                        threads[i].messages[j].problem = "上次回复被中断"
                    }
                }
            }
            fileURL = url
            storageReady = true
            selectedID = threads.first?.id
            if threads.isEmpty { newThread() }
        } catch { errorText = "无法读取本机聊天记录，已暂停写入以保留原文件。请解锁设备后重新打开 App。" }
    }

    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let token = try await auth.accessToken(for: accountID)
            let available = try await ResponsesClient.models(token: token)
            try Task.checkCancellation()
            models = available
            if !models.contains(where: { $0.slug == selectedModel }) {
                let preferred = selected?.model ?? ""
                selectedModel = models.first(where: { $0.slug == preferred })?.slug ?? models.first?.slug ?? ""
            }
            if models.isEmpty { errorText = "当前账户没有返回可展示的模型。请检查工作空间与套餐授权。" }
        } catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }

    func newThread() {
        guard !isSending, storageReady else { return }
        if let empty = threads.first(where: { $0.messages.isEmpty }) { selectedID = empty.id; return }
        let thread = ChatThread(model: selectedModel)
        threads.insert(thread, at: 0)
        selectedID = thread.id
        persist()
    }
    func select(_ thread: ChatThread) {
        guard !isSending else { return }
        selectedID = thread.id
        if models.contains(where: { $0.slug == thread.model }) { selectedModel = thread.model }
    }
    func delete(_ ids: Set<UUID>) {
        guard !isSending, storageReady else { return }
        threads.removeAll { ids.contains($0.id) }
        if let selectedID = selectedID, ids.contains(selectedID) { self.selectedID = threads.first?.id }
        if threads.isEmpty { newThread() } else { persist() }
    }
    func clearHistory() { delete(Set(threads.map(\.id))) }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, storageReady, !isSending,
              let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = String(title.prefix(80))
        persist()
    }

    @discardableResult func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, storageReady, !selectedModel.isEmpty,
              models.contains(where: { $0.slug == selectedModel }),
              let index = threads.firstIndex(where: { $0.id == selectedID }) else { return false }
        threads[index].messages.append(ChatMessage(role: .user, text: text))
        if threads[index].title == "新对话" { threads[index].title = String(text.prefix(28)) }
        startRequest(threadIndex: index)
        return true
    }
    func retry() {
        guard !isSending, storageReady, !selectedModel.isEmpty, let index = threads.firstIndex(where: { $0.id == selectedID }),
              let last = threads[index].messages.last, last.role == .assistant, last.status != .complete else { return }
        threads[index].messages.removeLast()
        startRequest(threadIndex: index)
    }

    private func startRequest(threadIndex index: Int) {
        guard storageReady, !selectedModel.isEmpty else { return }
        let history = threads[index].messages
        let response = ChatMessage(role: .assistant, text: "", status: .streaming)
        let threadID = threads[index].id
        let model = selectedModel
        threads[index].model = model
        threads[index].updated = Date()
        threads[index].messages.append(response)
        errorText = nil
        persist()
        guard errorText == nil else { mark(threadID, response.id, status: .failed, problem: "保存失败，未发送请求"); return }
        let runID = UUID()
        generation = runID
        isSending = true
        requestTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.generation == runID { self.isSending = false; self.requestTask = nil; self.generation = nil; self.persist() }
            }
            do {
                let token = try await self.auth.accessToken(for: self.accountID)
                try Task.checkCancellation()
                try await ResponsesClient.stream(token: token, model: model, history: history) { delta in
                    guard self.generation == runID,
                          let i = self.threads.firstIndex(where: { $0.id == threadID }),
                          let j = self.threads[i].messages.firstIndex(where: { $0.id == response.id }) else { return }
                    self.threads[i].messages[j].text += delta
                }
                try Task.checkCancellation()
                self.mark(threadID, response.id, status: .complete)
            } catch is CancellationError { self.mark(threadID, response.id, status: .cancelled, problem: "你已停止生成") }
            catch {
                self.mark(threadID, response.id, status: Task.isCancelled ? .cancelled : .failed,
                          problem: Task.isCancelled ? "你已停止生成" : error.localizedDescription)
            }
        }
    }

    func stop() { requestTask?.cancel() }

    private func mark(_ thread: UUID, _ message: UUID, status: ChatMessage.Status, problem: String? = nil) {
        guard let i = threads.firstIndex(where: { $0.id == thread }),
              let j = threads[i].messages.firstIndex(where: { $0.id == message }) else { return }
        threads[i].messages[j].status = status
        threads[i].messages[j].problem = problem
    }
    private func persist() {
        guard storageReady, let fileURL = fileURL else { return }
        do { try JSONEncoder().encode(threads).write(to: fileURL, options: [.atomic, .completeFileProtection]) }
        catch { errorText = "聊天记录未能保存到本机。请检查可用空间或设备锁定状态。" }
    }
}
