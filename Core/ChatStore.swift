import Foundation
import Combine

typealias ChatTransport = @MainActor (_ model: String, _ history: [ChatMessage], _ effort: ReasoningEffort,
                                     _ onDelta: @escaping (String) -> Void) async throws -> Void
typealias ChatAgentTransport = @MainActor (_ runtime: ToolRuntime, _ onDelta: @escaping (String) -> Void) async throws -> Void

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var threads: [ChatThread] = []
    @Published var selectedID: UUID?
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var selectedModel = ""
    @Published private(set) var generatingThreadIDs: Set<UUID> = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var storageReady = false
    @Published var errorText: String?
    @Published private(set) var approvals: [ToolApproval] = []
    @Published private(set) var importingThreadIDs: Set<UUID> = []
    @Published private(set) var waitingThreadIDs: Set<UUID> = []
    let mcpConnections: MCPConnections
    let lifecycle: GenerationLifecycle
    let workingMemory: WorkingMemoryStore
    private(set) var fileVault: FileVault?
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Error>] = [:]
    private let accountID: UUID
    private let auth: AuthManager
    private(set) var apiConnection: APIConnection?
    var connectionID: UUID { accountID }
    private let transport: ChatTransport?
    private let agentTransport: ChatAgentTransport?
    private var fileURL: URL?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var runs: [UUID: UUID] = [:]
    private var responseIDs: [UUID: UUID] = [:]
    private var pendingText: [UUID: String] = [:]
    private var inferenceText: [UUID: String] = [:]
    private var flushTasks: [UUID: Task<Void, Never>] = [:]
    private var draftTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var needsCheckpoint = false
    private let checkpointInterval: UInt64
    var selected: ChatThread? { threads.first { $0.id == selectedID } }
    var isSending: Bool { selectedID.map { generatingThreadIDs.contains($0) } ?? false }
    var isImporting: Bool { selectedID.map { importingThreadIDs.contains($0) } ?? false }
    var selectedApproval: ToolApproval? { approvals.first { $0.threadID == selectedID } }
    var toolSettings: ToolSettings { selected?.toolSettings ?? ToolSettings() }
    var isWaitingForForeground: Bool { selectedID.map { waitingThreadIDs.contains($0) } ?? false }
    var isAPIConnection: Bool { apiConnection != nil }
    var canUseConnection: Bool { isAPIConnection || (!auth.isBusy && auth.activeAccount?.tokens?.permitsInference == true) }
    var connectionName: String { apiConnection?.name ?? "ChatGPT" }
    var usageCaption: String { isAPIConnection ? "API 由服务商计费 · 对话保存在本机" : "ChatGPT 套餐 · 对话保存在本机" }
    var effortOptions: [ReasoningEffort] { ReasoningSupport.options(model: selectedModel, connection: apiConnection) }
    var selectedEffort: ReasoningEffort {
        guard let raw = selected?.reasoningEfforts?[selectedModel], let effort = ReasoningEffort(rawValue: raw),
              effortOptions.contains(effort) else { return .automatic }
        return effort
    }

    init(accountID: UUID, auth: AuthManager, apiConnection: APIConnection? = nil,
         storageDirectory: URL? = nil, transport: ChatTransport? = nil,
         mcpConnections: MCPConnections? = nil, agentTransport: ChatAgentTransport? = nil,
         checkpointInterval: UInt64 = 2_000_000_000, lifecycle: GenerationLifecycle? = nil,
         workingMemory: WorkingMemoryStore? = nil) {
        self.accountID = accountID; self.auth = auth; self.apiConnection = apiConnection; self.transport = transport
        self.mcpConnections = mcpConnections ?? MCPConnections(); self.agentTransport = agentTransport
        self.checkpointInterval = max(10_000_000, checkpointInterval)
        self.lifecycle = lifecycle ?? GenerationLifecycle()
        self.workingMemory = workingMemory ?? (storageDirectory == nil ? .shared : WorkingMemoryStore(memoryOnly: true))
        do {
            fileVault = try FileVault(accountID: accountID, root: storageDirectory?.appendingPathComponent("files"))
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
                        if let activities = threads[i].messages[j].toolActivities {
                            threads[i].messages[j].toolActivities = activities.map { var x = $0; if x.state == "running" { x.state = "cancelled"; x.detail = "上次执行被中断" }; return x }
                        }
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
            var catalog: [ModelChoice] = []
            if refresh {
                do {
                    let remote = try await APIChatClient.models(connection: connection)
                    try Task.checkCancellation(); ids += remote.map(\.slug); errorText = nil
                    catalog = remote
                    for model in remote {
                        if let efforts = model.reasoningEfforts {
                            if apiConnection?.modelReasoningEfforts == nil { apiConnection?.modelReasoningEfforts = [:] }
                            apiConnection?.modelReasoningEfforts?[model.slug] = efforts
                        }
                    }
                } catch is CancellationError { return }
                catch { errorText = "未能获取模型列表，仍可使用手动配置的模型。\n" + error.localizedDescription }
            }
            var seen = Set<String>()
            models = ids.filter { seen.insert($0).inserted }.map { id in
                catalog.first { $0.slug == id } ?? ModelChoice(slug: id, display_name: id, visibility: nil)
            }
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
        if let i = threads.firstIndex(where: { $0.id == selectedID }) { threads[i].model = selectedModel; persist() }
    }
    func selectModel(_ model: String) {
        guard !isSending, storageReady, models.contains(where: { $0.slug == model }),
              let i = threads.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedModel = model; threads[i].model = model; persist()
    }
    func selectEffort(_ effort: ReasoningEffort) {
        guard !isSending, storageReady, effort == .automatic || effortOptions.contains(effort),
              let i = threads.firstIndex(where: { $0.id == selectedID }) else { return }
        var choices = threads[i].reasoningEfforts ?? [:]
        if effort == .automatic { choices.removeValue(forKey: selectedModel) }
        else { choices[selectedModel] = effort.rawValue }
        threads[i].reasoningEfforts = choices.isEmpty ? nil : choices
        persist()
    }
    func newThread() {
        guard storageReady else { return }
        let choices = selected?.reasoningEfforts
        let settings = selected?.toolSettings
        if let index = threads.firstIndex(where: { $0.messages.isEmpty && ($0.draft ?? "").isEmpty && ($0.draftAttachments ?? []).isEmpty && !importingThreadIDs.contains($0.id) }) {
            selectedID = threads[index].id; threads[index].model = selectedModel
            threads[index].reasoningEfforts = choices; threads[index].toolSettings = settings; persist(); return
        }
        let thread = ChatThread(model: selectedModel, reasoningEfforts: choices, toolSettings: settings)
        threads.insert(thread, at: 0); selectedID = thread.id; persist()
    }
    func select(_ thread: ChatThread) {
        guard let current = threads.first(where: { $0.id == thread.id }) else { return }
        selectedID = thread.id
        selectedModel = models.first(where: { $0.slug == current.model })?.slug ?? models.first?.slug ?? ""
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
    func flushDrafts() {
        draftTask?.cancel(); draftTask = nil
        for id in Array(pendingText.keys) { flush(id) }
        persist()
    }
    func sceneChanged(active: Bool) {
        lifecycle.setActive(active)
        flushDrafts()
    }
    func delete(_ ids: Set<UUID>) {
        guard storageReady else { return }
        let previousFiles = referencedFiles()
        for id in ids { stop(threadID: id) }
        threads.removeAll { ids.contains($0.id) }
        if let selectedID = selectedID, ids.contains(selectedID) { self.selectedID = threads.first?.id }
        if threads.isEmpty { newThread() }
        else if let selected = selected { select(selected) }
        else { persist() }
        if persist() { removeUnused(previousFiles) }
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
        guard !isSending, !isImporting, canStart, let index = threads.firstIndex(where: { $0.id == selectedID }),
              !text.isEmpty || !(threads[index].draftAttachments ?? []).isEmpty else { return false }
        let files = threads[index].draftAttachments
        threads[index].messages.append(ChatMessage(role: .user, text: text.isEmpty ? "请分析这些附件。" : text, attachments: files))
        threads[index].draft = nil; threads[index].draftAttachments = nil
        if threads[index].title == "新对话" { threads[index].title = String((text.isEmpty ? files?.first?.name ?? "附件对话" : text).prefix(28)) }
        startRequest(threadIndex: index); return true
    }
    func retry() {
        guard !isSending, canStart, let index = threads.firstIndex(where: { $0.id == selectedID }),
              var last = threads[index].messages.last, last.role == .assistant else { return }
        threads[index].messages.removeLast()
        last.beginRegeneration(model: selectedModel, reasoningEffort: selectedEffort == .automatic ? nil : selectedEffort.rawValue)
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
        let threadID = threads[index].id; let model = selectedModel; let effort = selectedEffort
        let settings = toolSettings; let servers = mcpConnections.servers
        let response = existing ?? ChatMessage(role: .assistant, text: "", status: .streaming, model: model,
                                               reasoningEffort: effort == .automatic ? nil : effort.rawValue)
        threads[index].model = model; threads[index].updated = Date()
        threads[index].messages.append(response); errorText = nil
        guard persist() else { mark(threadID, response.id, status: .failed, problem: "保存失败，未发送请求"); return }
        let runID = UUID(); runs[threadID] = runID; responseIDs[threadID] = response.id
        generatingThreadIDs.insert(threadID)
        lifecycle.setWorking(true)
        requests[threadID] = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.runs[threadID] == runID { self.cleanup(threadID); self.persist() } }
            do {
                let onDelta: (String) -> Void = { [weak self] delta in self?.buffer(delta, threadID: threadID, runID: runID) }
                if let transport = self.transport { try await transport(model, history, effort, onDelta) }
                else {
                    guard let vault = self.fileVault else { throw AppFailure.message("附件存储未就绪。") }
                    let token: String
                    if let connection = self.apiConnection { token = connection.apiKey }
                    else { token = try await self.auth.accessToken(for: self.accountID) }
                    try Task.checkCancellation()
                    let runtime = ToolRuntime(vault: vault, files: history.flatMap { $0.attachments ?? [] }, servers: servers,
                        approve: { [weak self] name, arguments in
                            guard let self = self else { throw CancellationError() }
                            return try await self.requestApproval(threadID: threadID, runID: runID, name: name, arguments: arguments)
                        }, event: { [weak self] event in self?.receive(event, threadID: threadID, runID: runID) },
                        authorizeMCP: { [weak self] server in
                            guard let self = self else { throw CancellationError() }
                            return try await self.mcpConnections.authorized(server)
                        }, workingMemory: self.workingMemory)
                    if let agent = self.agentTransport { try await agent(runtime, onDelta) }
                    else {
                        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: token, connection: self.apiConnection), model: model,
                            history: history, effort: effort, settings: settings, runtime: runtime, delta: onDelta, lifecycle: self.lifecycle)
                    }
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
        scheduleCheckpoint()
        guard flushTasks[threadID] == nil else { return }
        flushTasks[threadID] = Task { [weak self] in
            let length = self?.threads.first(where: { $0.id == threadID })?.messages.last?.text.utf8.count ?? 0
            let delay: UInt64 = length > 64_000 ? 120_000_000 : length > 16_000 ? 80_000_000 : 40_000_000
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
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
        let ids = approvals.filter { $0.threadID == threadID }.map(\.id)
        for id in ids { approvalContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        approvals.removeAll { $0.threadID == threadID }
        flushTasks.removeValue(forKey: threadID)?.cancel()
        pendingText.removeValue(forKey: threadID); responseIDs.removeValue(forKey: threadID)
        requests.removeValue(forKey: threadID); runs.removeValue(forKey: threadID); generatingThreadIDs.remove(threadID)
        inferenceText.removeValue(forKey: threadID); waitingThreadIDs.remove(threadID)
        lifecycle.setWorking(!runs.isEmpty)
        if runs.isEmpty { checkpointTask?.cancel(); checkpointTask = nil }
    }
    private func scheduleCheckpoint() {
        needsCheckpoint = true
        guard checkpointTask == nil, !runs.isEmpty else { return }
        let interval = checkpointInterval
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: interval) } catch { return }
            guard !Task.isCancelled, let self = self else { return }
            self.checkpointTask = nil
            for id in Array(self.pendingText.keys) { self.flush(id) }
            if self.needsCheckpoint { self.persist() }
            if self.needsCheckpoint && !self.runs.isEmpty { self.scheduleCheckpoint() }
        }
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
        if status != .streaming, let activities = threads[i].messages[j].toolActivities {
            threads[i].messages[j].toolActivities = activities.map { var x = $0; if x.state == "running" { x.state = status == .complete ? "complete" : "cancelled"; x.detail = status == .complete ? "已完成" : "已中断（远程操作可能仍在继续）" }; return x }
            threads[i].messages[j].recordVersion()
        }
    }
    func setToolSettings(_ settings: ToolSettings) {
        guard !isSending, let i = threads.firstIndex(where: { $0.id == selectedID }) else { return }
        threads[i].toolSettings = settings; persist()
    }
    func importFiles(_ urls: [URL], threadID: UUID? = nil) async {
        guard storageReady, let id = threadID ?? selectedID, let vault = fileVault,
              let thread = threads.first(where: { $0.id == id }) else { errorText = "原对话已不可用，未添加附件。"; return }
        guard !importingThreadIDs.contains(id), (thread.draftAttachments?.count ?? 0) + urls.count <= 4 else {
            errorText = "每条消息最多添加 4 个附件。"; return
        }
        importingThreadIDs.insert(id); defer { importingThreadIDs.remove(id) }
        for url in urls {
            do {
                let file = try await FileWork.run { try vault.importFile(url) }
                guard !Task.isCancelled, let i = threads.firstIndex(where: { $0.id == id }) else { vault.remove(file); return }
                var files = threads[i].draftAttachments ?? []; files.append(file); threads[i].draftAttachments = files
                if !persist() { threads[i].draftAttachments?.removeAll { $0.id == file.id }; vault.remove(file) }
            } catch is CancellationError { return }
            catch { errorText = error.localizedDescription }
        }
    }
    func importPhoto(_ data: Data, threadID: UUID? = nil) async {
        guard let vault = fileVault, data.count <= 10_000_000 else { errorText = "图片过大，最多 10 MB。"; return }
        guard let target = threadID ?? selectedID else { errorText = "原对话已不可用，未添加附件。"; return }
        let url = vault.directory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await FileWork.run { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
            try Task.checkCancellation()
            await importFiles([url], threadID: target)
        }
        catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }
    func removeDraftFile(_ id: UUID) {
        guard let i = threads.firstIndex(where: { $0.id == selectedID }) else { return }
        let previous = referencedFiles(); threads[i].draftAttachments?.removeAll { $0.id == id }
        if persist() { removeUnused(previous) }
    }
    private func referencedFiles() -> [ChatAttachment] {
        threads.flatMap { ($0.draftAttachments ?? []) + $0.messages.flatMap { ($0.attachments ?? []) + ($0.versions ?? []).flatMap { $0.attachments ?? [] } } }
    }
    private func removeUnused(_ previous: [ChatAttachment]) {
        let current = Set(referencedFiles().map(\.id))
        for file in previous where !current.contains(file.id) { fileVault?.remove(file) }
    }
    private func receive(_ event: ToolEvent, threadID: UUID, runID: UUID) {
        guard runs[threadID] == runID, let responseID = responseIDs[threadID],
              let i = threads.firstIndex(where: { $0.id == threadID }),
              let j = threads[i].messages.firstIndex(where: { $0.id == responseID }) else {
            if case .file(let file) = event { fileVault?.remove(file) }; return
        }
        switch event {
        case .beginInference:
            flush(threadID); inferenceText[threadID] = threads[i].messages[j].text
            return
        case .restartInference:
            flush(threadID)
            if let checkpoint = inferenceText[threadID] { threads[i].messages[j].text = checkpoint }
            scheduleCheckpoint(); return
        case .waitingForForeground(let waiting):
            if waiting { waitingThreadIDs.insert(threadID) } else { waitingThreadIDs.remove(threadID) }
            return
        case .file(let file):
            var files = threads[i].messages[j].attachments ?? []; files.append(file); threads[i].messages[j].attachments = files
        case .activity(let value):
            flush(threadID)
            var activities = threads[i].messages[j].toolActivities ?? []
            var value = value
            if let index = activities.firstIndex(where: { $0.id == value.id }) {
                value.textOffset = activities[index].textOffset
                guard activities[index] != value else { return }
                activities[index] = value
            }
            else { value.textOffset = threads[i].messages[j].text.count; activities.append(value) }
            threads[i].messages[j].toolActivities = activities
        }
        if case .file = event { flush(threadID); persist() }
        else { scheduleCheckpoint() }
    }
    private func requestApproval(threadID: UUID, runID: UUID, name: String, arguments: String) async throws -> Bool {
        try Task.checkCancellation()
        guard runs[threadID] == runID else { throw CancellationError() }
        let value = ToolApproval(threadID: threadID, runID: runID, name: name, arguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            approvalContinuations[value.id] = continuation; approvals.append(value)
        }
    }
    func resolveApproval(_ id: UUID, allow: Bool) {
        guard let approval = approvals.first(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        let continuation = approvalContinuations.removeValue(forKey: id)
        if runs[approval.threadID] == approval.runID { continuation?.resume(returning: allow) }
        else { continuation?.resume(throwing: CancellationError()) }
    }
    @discardableResult private func persist() -> Bool {
        guard storageReady, let fileURL = fileURL else { return false }
        do {
            try JSONEncoder().encode(ChatArchive(threads: threads, selectedID: selectedID))
                .write(to: fileURL, options: [.atomic, .completeFileProtection])
            needsCheckpoint = !pendingText.isEmpty
            return true
        } catch { errorText = "聊天记录未能保存到本机。请检查可用空间或设备锁定状态。"; return false }
    }
}
