import Foundation

struct ModelChoice: Codable, Identifiable, Equatable {
    let slug: String
    let display_name: String
    let visibility: String?
    var reasoningEfforts: [String]? = nil
    var id: String { slug }
}

enum ModelCatalog {
    static func merged(manual: [String], remote: [ModelChoice]) -> [ModelChoice] {
        var seen = Set<String>()
        var byID: [String: ModelChoice] = [:]
        for model in remote where byID[model.slug] == nil { byID[model.slug] = model }
        return (manual + remote.map(\.slug)).filter { !$0.isEmpty && seen.insert($0).inserted }.map {
            byID[$0] ?? ModelChoice(slug: $0, display_name: $0, visibility: nil)
        }
    }
}

// Cache only model metadata, separated by connection. Never store tokens or chats.
@MainActor final class ModelCatalogCache {
    static let shared = ModelCatalogCache()
    private let defaults: UserDefaults?
    private var memory: [UUID: [ModelChoice]] = [:]
    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
    private func key(_ id: UUID) -> String { "modelCatalog.v1." + id.uuidString }
    func models(for id: UUID) -> [ModelChoice] {
        if let models = memory[id] { return models }
        guard let data = defaults?.data(forKey: key(id)), data.count <= 500_000,
              let models = try? JSONDecoder().decode([ModelChoice].self, from: data) else { return [] }
        let safe = bounded(models); memory[id] = safe; return safe
    }
    func save(_ models: [ModelChoice], for id: UUID) {
        let safe = bounded(models)
        guard let data = try? JSONEncoder().encode(safe), data.count <= 500_000 else { return }
        memory[id] = safe; defaults?.set(data, forKey: key(id))
    }
    func invalidate(_ id: UUID) { memory.removeValue(forKey: id); defaults?.removeObject(forKey: key(id)) }
    private func bounded(_ models: [ModelChoice]) -> [ModelChoice] {
        ModelCatalog.merged(manual: [], remote: Array(models.prefix(1000))).filter {
            $0.slug.count <= 256 && $0.display_name.count <= 256 && ($0.reasoningEfforts?.count ?? 0) <= 16
        }
    }
}
