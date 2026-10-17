import Foundation
import Combine

typealias ChatTransport = @MainActor (_ model: String, _ history: [ChatMessage],
                                     _ onDelta: @escaping (String) -> Void) async throws -> Void

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var threads: [ChatThread] = []
    @Published var selectedID: UUID?
    @Published private(set) var models: [ModelChoice] = []
    @Published var selectedModel = ""
    @Published private(set) var generatingThreadIDs: Set<UUID> = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var storageReady = false
    @Published var errorText: String?
    private let accountID: UUID
    private let auth: AuthManager
    let apiConnection: APIConnection?
    private let transport: ChatTransport?
    private var fileURL: URL?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var runs: [UUID: UUID] = [:]
    private var responseIDs: [UUID: UUID] = [:]
    private var pendingText: [UUID: String] = [:]
    private var flushTasks: [UUID: Task<Void, Never>] = [:]
    private var draftTask: Task<Void, Never>?
    var selected: ChatThread? { threads.first { $0.id == selectedID } }
    var isSending: Bool { selectedID.map { generatingThreadIDs.contains($0) } ?? false }
    var isAPIConnection: Bool { apiConnection != nil }
    var canUseConnection: Bool { isAPIConnection || (!auth.isBusy && auth.activeAccount?.tokens?.permitsInference == true) }
    var connectionName: String { apiConnection?.name ?? "ChatGPT" }
    var usageCaption: String { isAPIConnection ? "API 由服务商计费 · 对话保存在本机" : "ChatGPT 套餐 · 对话保存在本机" }

    init(accountID: UUID, auth: AuthManager, apiConnection: APIConnection? = nil,
         storageDirectory: URL? = nil, transport: ChatTransport? = nil) {
        self.accountID = accountID; self.auth = auth; self.apiConnection = apiConnection; self.transport = transport
        do {
            var directory = try storageDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LiaoChat/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let url = directory.appendingPathComponent(accountID.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try ChatArchive.decode(Data(contentsOf: url)); threads = archive.threads
                selectedID = threads.contains(where: { $0.id == archive.selectedID }) ? archive.selectedID : threads.first?.id
                for i in threads.indices {
                    for j in threads[i].messages.indices where threads[i].messages[j].status == .streaming {
                        threads[i].messages[j].status = .cancelled
                        threads[i].messages[j].problem = "上次回复被中断"
                        threads[i].messages[j].recordVersion()
                    }
                }
            }
            fileURL = url; storageReady = true; selectedModel = selected?.model ?? ""
            if threads.isEmpty { newThread() }
        } catch { errorText = "无法读取本机聊天记录，已暂停写入以保留原文件。请解锁设备后重新打开 App。" }
    }
    func loadModels(refresh: Bool = false) async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        if let connection = apiConnection {
            var ids = connection.modelIDs
            if refresh {
                do {
                    let remote = try await APIChatClient.models(connection: connection)
                    try Task.checkCancellation(); ids += remote.map(\.slug); errorText = nil
                } catch is CancellationError { return }
                catch { errorText = "未能获取模型列表，仍可使用手动配置的模型。\n" + error.localizedDescription }
            }
            var seen = Set<String>()
            models = ids.filter { seen.insert($0).inserted }.map { ModelChoice(slug: $0, display_name: $0, visibility: nil) }
        } else {
            do {
                let token = try await auth.accessToken(for: accountID)
                let available = try await ResponsesClient.models(token: token)
                try Task.checkCancellation(); models = available
                if models.isEmpty { errorText = "当前账户没有返回可展示的模型。请检查工作空间与套餐授权。" }
            } catch is CancellationError { return }
            catch { errorText = error.localizedDescription; return }
        }
        if !models.contains(where: { $0.slug == selectedModel }) {
            selectedModel = models.first(where: { $0.slug == selected?.model })?.slug ?? models.first?.slug ?? ""
        }
    }
    func newThread() {
        guard storageReady else { return }
        if let index = threads.firstIndex(where: { $0.messages.isEmpty && ($0.draft ?? "").isEmpty }) {
            selectedID = threads[index].id; threads[index].model = selectedModel; persist(); return
        }
        let thread = ChatThread(model: selectedModel)
        threads.insert(thread, at: 0); selectedID = thread.id; persist()
    }
    func select(_ thread: ChatThread) {
        guard threads.contains(where: { $0.id == thread.id }) else { return }
        selectedID = thread.id
        if models.contains(where: { $0.slug == thread.model }) { selectedModel = thread.model }
        persist()
    }
    func updateDraft(_ text: String) {
        guard storageReady, let i = threads.firstIndex(where: { $0.id == selectedID }) else { return }
        threads[i].draft = text; draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            self?.persist()
        }
    }
    func flushDrafts() { draftTask?.cancel(); draftTask = nil; persist() }
    func delete(_ ids: Set<UUID>) {
        guard storageReady else { return }
        for id in ids { stop(threadID: id) }
        threads.removeAll { ids.contains($0.id) }
        if let selectedID = selectedID, ids.contains(selectedID) { self.selectedID = threads.first?.id }
        if threads.isEmpty { newThread() } else { persist() }
    }
    func clearHistory() { delete(Set(threads.map(\.id))) }
    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, storageReady, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = String(title.prefix(80)); persist()
    }
    func togglePin(_ id: UUID) {
        guard storageReady, let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isPinned = !(threads[i].isPinned ?? false); persist()
    }
    private var canStart: Bool {
        storageReady && canUseConnection && !selectedModel.isEmpty && models.contains(where: { $0.slug == selectedModel })
    }
    @discardableResult func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, canStart, let index = threads.firstIndex(where: { $0.id == selectedID }) else { return false }
        threads[index].messages.append(ChatMessage(role: .user, text: text)); threads[index].draft = nil
        if threads[index].title == "新对话" { threads[index].title = String(text.prefix(28)) }
        startRequest(threadIndex: index); return true
    }
    func retry() {
        guard !isSending, canStart, let index = threads.firstIndex(where: { $0.id == selectedID }),
              var last = threads[index].messages.last, last.role == .assistant else { return }
        threads[index].messages.removeLast(); last.beginRegeneration(model: selectedModel)
        startRequest(threadIndex: index, response: last)
    }
    @discardableResult func editAndSend(_ messageID: UUID, text: String) -> Bool {
        guard canStart, let source = selected, let branch = source.editing(messageID, text: text) else { return false }
        threads.insert(branch, at: 0); selectedID = branch.id
        startRequest(threadIndex: 0); return true
    }
    func chooseVersion(messageID: UUID, index: Int) {
        guard !isSending, let i = threads.firstIndex(where: { $0.id == selectedID }),
              let j = threads[i].messages.indices.last, threads[i].messages[j].id == messageID else { return }
        if threads[i].messages[j].chooseVersion(index) { persist() }
    }
    private func startRequest(threadIndex index: Int, response existing: ChatMessage? = nil) {
        let history = threads[index].messages
        let response = existing ?? ChatMessage(role: .assistant, text: "", status: .streaming, model: selectedModel)
        let threadID = threads[index].id; let model = selectedModel
        threads[index].model = model; threads[index].updated = Date()
        threads[index].messages.append(response); errorText = nil
        guard persist() else { mark(threadID, response.id, status: .failed, problem: "保存失败，未发送请求"); return }
        let runID = UUID(); runs[threadID] = runID; responseIDs[threadID] = response.id
        generatingThreadIDs.insert(threadID)
        requests[threadID] = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.runs[threadID] == runID { self.cleanup(threadID); self.persist() } }
            do {
                let onDelta: (String) -> Void = { [weak self] delta in self?.buffer(delta, threadID: threadID, runID: runID) }
                if let transport = self.transport { try await transport(model, history, onDelta) }
                else if let connection = self.apiConnection {
                    try await APIChatClient.stream(connection: connection, model: model, history: history, onDelta: onDelta)
                } else {
                    let token = try await self.auth.accessToken(for: self.accountID); try Task.checkCancellation()
                    try await ResponsesClient.stream(token: token, model: model, history: history, onDelta: onDelta)
                }
                guard self.runs[threadID] == runID else { return }
                try Task.checkCancellation(); self.flush(threadID)
                self.mark(threadID, response.id, status: .complete)
            } catch {
                guard self.runs[threadID] == runID else { return }
                self.flush(threadID)
                let cancelled = Task.isCancelled || error is CancellationError
                self.mark(threadID, response.id, status: cancelled ? .cancelled : .failed,
                          problem: cancelled ? "已停止生成" : error.localizedDescription,
                          diagnostic: cancelled ? nil : (error as? ResponseFailure)?.diagnostic)
            }
        }
    }
    private func buffer(_ delta: String, threadID: UUID, runID: UUID) {
        guard runs[threadID] == runID, !delta.isEmpty else { return }
        pendingText[threadID, default: ""] += delta
        guard flushTasks[threadID] == nil else { return }
        flushTasks[threadID] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            guard let self = self, self.runs[threadID] == runID else { return }
            self.flush(threadID)
        }
    }
    private func flush(_ threadID: UUID) {
        flushTasks.removeValue(forKey: threadID)?.cancel()
        guard let text = pendingText.removeValue(forKey: threadID), let responseID = responseIDs[threadID],
              let i = threads.firstIndex(where: { $0.id == threadID }),
              let j = threads[i].messages.firstIndex(where: { $0.id == responseID }) else { return }
        threads[i].messages[j].text += text
    }
    private func cleanup(_ threadID: UUID) {
        flushTasks.removeValue(forKey: threadID)?.cancel()
        pendingText.removeValue(forKey: threadID); responseIDs.removeValue(forKey: threadID)
        requests.removeValue(forKey: threadID); runs.removeValue(forKey: threadID); generatingThreadIDs.remove(threadID)
    }
    func stop() { if let id = selectedID { stop(threadID: id) } }
    func stop(threadID: UUID) {
        guard runs[threadID] != nil else { return }
        requests[threadID]?.cancel(); flush(threadID)
        if let responseID = responseIDs[threadID] { mark(threadID, responseID, status: .cancelled, problem: "已停止生成") }
        cleanup(threadID); persist()
    }
    func stopAll() { for id in Array(runs.keys) { stop(threadID: id) }; flushDrafts() }
    private func mark(_ thread: UUID, _ message: UUID, status: ChatMessage.Status, problem: String? = nil, diagnostic: String? = nil) {
        guard let i = threads.firstIndex(where: { $0.id == thread }),
              let j = threads[i].messages.firstIndex(where: { $0.id == message }) else { return }
        threads[i].messages[j].status = status; threads[i].messages[j].problem = problem
        threads[i].messages[j].diagnostic = diagnostic; threads[i].messages[j].recordVersion()
    }
    @discardableResult private func persist() -> Bool {
        guard storageReady, let fileURL = fileURL else { return false }
        do {
            try JSONEncoder().encode(ChatArchive(threads: threads, selectedID: selectedID))
                .write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch { errorText = "聊天记录未能保存到本机。请检查可用空间或设备锁定状态。"; return false }
    }
}
