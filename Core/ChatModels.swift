import Foundation

struct ReplyVersion: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var status: ChatMessage.Status
    var problem: String?
    var diagnostic: String?
    var model: String?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case complete, streaming, failed, cancelled }
    var id = UUID()
    let role: Role
    var text: String
    var status: Status = .complete
    var problem: String?
    var diagnostic: String?
    var model: String?
    var versions: [ReplyVersion]?
    var versionIndex: Int?
    var versionCount: Int { versions?.count ?? 1 }
    var activeVersion: Int { versionIndex ?? 0 }
    private var snapshot: ReplyVersion {
        ReplyVersion(text: text, status: status, problem: problem, diagnostic: diagnostic, model: model)
    }
    mutating func recordVersion() {
        guard let index = versionIndex, versions?.indices.contains(index) == true else { return }
        let version = snapshot
        versions?[index] = version
    }
    mutating func beginRegeneration(model: String) {
        recordVersion()
        if versions == nil { versions = [snapshot] }
        text = ""; status = .streaming; problem = nil; diagnostic = nil; self.model = model
        versionIndex = versions?.count ?? 0
        let version = snapshot
        versions?.append(version)
    }
    @discardableResult mutating func chooseVersion(_ index: Int) -> Bool {
        guard role == .assistant, status != .streaming, let versions = versions,
              versions.indices.contains(index) else { return false }
        recordVersion()
        guard let version = self.versions?[index] else { return false }
        text = version.text; status = version.status; problem = version.problem
        diagnostic = version.diagnostic; model = version.model; versionIndex = index
        return true
    }
}

struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title = "新对话"
    var updated = Date()
    var model = ""
    var messages: [ChatMessage] = []
    var draft: String?
    var isPinned: Bool?
    var parentID: UUID?

    func editing(_ messageID: UUID, text: String) -> ChatThread? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .user else { return nil }
        var branch = ChatThread(title: String(text.prefix(28)), model: model,
                                messages: Array(messages.prefix(index)), parentID: id)
        branch.messages.append(ChatMessage(role: .user, text: text))
        return branch
    }
    var markdown: String {
        "# " + title + "\n\n" + messages.map { message in
            let role = message.role == .user ? "你" : "OpenChat"
            return "## " + role + "\n\n" + (message.text.isEmpty ? "（没有回复内容）" : message.text)
        }.joined(separator: "\n\n---\n\n")
    }
}

struct ChatArchive: Codable {
    var threads: [ChatThread]
    var selectedID: UUID?
    static func decode(_ data: Data) throws -> ChatArchive {
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(ChatArchive.self, from: data) { return archive }
        let threads = try decoder.decode([ChatThread].self, from: data)
        return ChatArchive(threads: threads, selectedID: threads.first?.id)
    }
}
