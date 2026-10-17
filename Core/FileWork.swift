import Foundation

// File parsing/compression and disk writes must not occupy the UI executor.
// Cancellation is forwarded to the worker; operations own cleanup of any file
// they create, so a cancelled task cannot discard a saved-but-untracked file.
enum FileWork {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func save(_ data: Data, name: String, vault: FileVault, extractedText: String? = nil, requireExtraction: Bool = false) throws -> ChatAttachment {
        try Task.checkCancellation()
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let text: String?
        if let extractedText = extractedText { text = extractedText }
        else if requireExtraction { text = try FileFormats.extract(data, ext: ext) }
        else { text = try? FileFormats.extract(data, ext: ext) }
        try Task.checkCancellation()
        return try vault.save(data: data, name: name, text: text)
    }
}
