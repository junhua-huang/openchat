import Foundation
import Combine

@MainActor final class MCPDiscoveryStore: ObservableObject {
    @Published private(set) var entries: [MCPListing] = []
    @Published private(set) var vendorEntries: [MCPListing] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published private(set) var nextCursor: String?
    private let client: MCPRegistryClient
    private var requestID = UUID()
    private var term = ""
    private var completedQuery: String?
    private var cursors = Set<String>()
    init(client: MCPRegistryClient = MCPRegistryClient()) { self.client = client }
    func search(_ query: String, debounce: Bool = true) async {
        // Returning from a detail page restarts SwiftUI's task. Retain loaded
        // pages instead of discarding them and repeating a slow public request.
        if debounce, query == term, completedQuery == query { return }
        term = query; entries = []; nextCursor = nil; cursors = []
        completedQuery = nil
        // Vendor matches are local and available immediately, including offline.
        // A slow/unavailable community registry must not hide known services.
        vendorEntries = MCPVendorCatalog.matching(query)
        let id = UUID(); requestID = id; problem = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { loading = false; return }
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            if debounce { try await Task.sleep(nanoseconds: 350_000_000) }
            let page = try await client.search(query)
            try Task.checkCancellation()
            guard requestID == id else { return }
            entries = MCPRegistryClient.distinct(page.entries, excluding: vendorEntries); nextCursor = page.nextCursor
            completedQuery = query
        } catch is CancellationError { }
        catch { if requestID == id && !Task.isCancelled { problem = error.localizedDescription } }
    }
    func more() async {
        guard !loading, let cursor = nextCursor, cursors.insert(cursor).inserted else { return }
        let id = UUID(); requestID = id; let query = term
        loading = true; problem = nil
        defer { if requestID == id { loading = false } }
        do {
            let page = try await client.search(query, cursor: cursor)
            try Task.checkCancellation()
            guard requestID == id else { return }
            entries += MCPRegistryClient.distinct(page.entries, excluding: vendorEntries + entries)
            if entries.count > 500 { entries = Array(entries.prefix(500)) }
            nextCursor = entries.count >= 500 || page.nextCursor.map({ cursors.contains($0) }) == true ? nil : page.nextCursor
        } catch is CancellationError { if requestID == id { cursors.remove(cursor) } }
        catch { if requestID == id && !Task.isCancelled { cursors.remove(cursor); problem = error.localizedDescription } }
    }
}
