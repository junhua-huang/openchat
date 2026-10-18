import Foundation

// Some compatible services send completed items but omit them from the terminal
// envelope. Keep the actual items, including final encrypted reasoning, until a
// real response.completed event validates the turn. Never execute partial calls.
struct ResponsesOutput {
    private var items: [Int: [String: Any]] = [:]
    private var finalized = Set<Int>()
    private var sizes: [Int: Int] = [:]
    private var totalBytes = 0

    mutating func consume(_ event: [String: Any]) throws {
        let type = event["type"] as? String ?? ""
        guard ["response.output_item.added", "response.output_item.done",
               "response.function_call_arguments.delta", "response.function_call_arguments.done"].contains(type) else { return }
        guard let index = event["output_index"] as? Int, (0..<256).contains(index) else { throw invalid() }
        var item = items[index] ?? [:]
        var size = sizes[index] ?? 0
        if let incoming = event["item"] as? [String: Any] {
            try checkIdentity(item, incoming)
            // A completed item is authoritative. Do not append final arguments
            // to the already accumulated fragments or replay a duplicate event.
            if type == "response.output_item.done" || !finalized.contains(index) {
                item = incoming
                size = try bounded(item)
            }
            if type == "response.output_item.done" { finalized.insert(index) }
        } else if type.hasPrefix("response.function_call_arguments.") {
            guard let id = event["item_id"] as? String, !id.isEmpty else { throw invalid() }
            try checkIdentity(item, ["id": id, "type": "function_call"])
            item["id"] = id; item["type"] = "function_call"
            if type.hasSuffix(".done") {
                guard let arguments = event["arguments"] as? String else { throw invalid() }
                item["arguments"] = arguments; item["status"] = "completed"
                size = try bounded(item)
                finalized.insert(index)
            } else if !finalized.contains(index) {
                let fragment = event["delta"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? ""
                guard arguments.utf8.count + fragment.utf8.count <= 256_000 else { throw invalid() }
                item["arguments"] = arguments + fragment
                size += fragment.utf8.count
            }
        } else { throw invalid() }
        totalBytes += size - (sizes[index] ?? 0)
        guard totalBytes <= 32_000_000 else { throw invalid() }
        sizes[index] = size
        items[index] = item
    }

    func finish(_ terminal: [[String: Any]]) throws -> [[String: Any]] {
        guard terminal.count <= 256 else { throw invalid() }
        var merged = items
        var complete = finalized
        for (index, item) in terminal.enumerated() {
            _ = try bounded(item)
            let id = item["id"] as? String
            let match = id.flatMap { id in merged.first { $0.value["id"] as? String == id }?.key }
                ?? (merged[index]?["id"] == nil || id == nil ? index : nil)
            let slot = match ?? ((merged.keys.max() ?? -1) + 1)
            if let existing = merged[slot] {
                try checkIdentity(existing, item)
                var value = existing.merging(item) { _, new in new }
                // Final item events can have fuller reasoning than the terminal
                // summary. Preserve that exact completed item for the next turn.
                if finalized.contains(slot), existing["type"] as? String == "reasoning" { value = existing }
                if finalized.contains(slot), existing["type"] as? String == "function_call" {
                    if let a = existing["arguments"] as? String, let b = item["arguments"] as? String,
                       !b.isEmpty, a != b { throw invalid() }
                    value["arguments"] = existing["arguments"]
                }
                merged[slot] = value
            } else { merged[slot] = item }
            complete.insert(slot)
        }
        var output: [[String: Any]] = []
        var ids = Set<String>(); var total = 0
        for (index, item) in merged.sorted(by: { $0.key < $1.key }) {
            if let id = item["id"] as? String, !ids.insert(id).inserted { throw invalid() }
            let kind = item["type"] as? String ?? ""
            if kind == "function_call" {
                guard complete.contains(index), let callID = item["call_id"] as? String, !callID.isEmpty,
                      let name = item["name"] as? String, !name.isEmpty,
                      item["status"] == nil || item["status"] as? String == "completed",
                      let arguments = item["arguments"] as? String, arguments.utf8.count <= 256_000,
                      let data = arguments.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw invalid() }
            } else if !complete.contains(index) { continue }
            total += try JSONSerialization.data(withJSONObject: item).count
            guard total <= 32_000_000 else { throw invalid() }
            output.append(item)
        }
        return output
    }

    private func checkIdentity(_ old: [String: Any], _ new: [String: Any]) throws {
        for key in ["id", "type", "call_id", "name"] {
            if let a = old[key] as? String, let b = new[key] as? String, !a.isEmpty, !b.isEmpty, a != b { throw invalid() }
        }
    }
    private func bounded(_ item: [String: Any]) throws -> Int {
        let bytes = try JSONSerialization.data(withJSONObject: item).count
        guard bytes <= 16_000_000 else { throw invalid() }
        if let args = item["arguments"] as? String, args.utf8.count > 256_000 { throw invalid() }
        return bytes
    }
    private func invalid() -> AppFailure { .message("服务返回的工具结果不完整或相互冲突，已停止以免执行错误操作。请重试或更换模型。") }
}
