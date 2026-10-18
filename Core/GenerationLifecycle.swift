import UIKit

// Protect short background work. If iOS suspends a stream, retry only that
// inference turn after foregrounding; completed local/MCP calls stay outside it.
@MainActor final class GenerationLifecycle {
    private(set) var isActive = true
    private(set) var backgroundEpoch = 0
    private var expired = false
    private var working = false
    private let managesSystemTask: Bool
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var inferences: [UUID: () -> Void] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(managesSystemTask: Bool = true) { self.managesSystemTask = managesSystemTask }
    func setWorking(_ value: Bool) {
        working = value
        if value { protect() } else { endProtection() }
    }
    func setActive(_ value: Bool) {
        guard value != isActive else { return }
        isActive = value
        if value {
            expired = false
            let pending = waiters.values; waiters.removeAll()
            pending.forEach { $0.resume() }
            if working { protect() }
        } else { backgroundEpoch += 1 }
    }
    private func protect() {
        guard managesSystemTask, assertion == .invalid, !expired else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "OpenChat reply") { [weak self] in
            self?.expireBackgroundTime()
        }
    }
    private func endProtection() {
        guard assertion != .invalid else { return }
        let value = assertion; assertion = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }
    func expireBackgroundTime() {
        expired = true
        for cancel in inferences.values { cancel() }
        endProtection()
    }
    private func awaitForeground() async throws {
        try Task.checkCancellation()
        if isActive { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
    func infer<T>(waiting: @escaping (Bool) -> Void, restarting: @escaping () -> Void,
                  operation: @escaping @MainActor () async throws -> T) async throws -> T {
        var recovered = false
        if expired && !isActive {
            waiting(true)
            do { try await awaitForeground(); waiting(false) }
            catch { waiting(false); throw error }
        }
        while true {
            try Task.checkCancellation()
            let epoch = backgroundEpoch; let id = UUID()
            let task = Task { try await operation() }
            inferences[id] = { task.cancel() }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                inferences.removeValue(forKey: id); return result
            } catch {
                inferences.removeValue(forKey: id)
                try Task.checkCancellation()
                guard !recovered, (!isActive || backgroundEpoch != epoch), Self.isInterruption(error) else { throw error }
                recovered = true; waiting(true)
                defer { waiting(false) }
                try await awaitForeground()
                restarting()
            }
        }
    }
    private static func isInterruption(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError {
            return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cancelled].contains(url.code)
        }
        if let failure = error as? ResponseFailure { return failure.diagnostic.contains("Body: sse_interrupted") }
        return false
    }
}
