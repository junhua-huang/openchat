import Foundation
import Network

@MainActor
final class LoopbackServer {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    var accept: ((URL) -> Bool)?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self, self.listener === server else { return }
                    switch state {
                    case .ready:
                        guard let port = server.port, let pending = self.startContinuation else { return }
                        self.startContinuation = nil
                        pending.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                    case .failed:
                        self.stop()
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self = self, self.listener === server else { connection.cancel(); return }
                    self.receive(connection)
                }
            }
            server.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self = self, self.listener === server, self.startContinuation != nil else { return }
                self.stop()
            }
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        startContinuation?.resume(throwing: AppFailure.message("无法启动设备本地登录回调。"))
        startContinuation = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        accept = nil
    }

    private func receive(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, accumulated: Data())
        // A stray local connection must not hold a socket indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }
    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, done, error in
            Task { @MainActor in
                guard let self = self, self.connections[id] != nil else { return }
                var data = accumulated
                if let chunk = chunk { data.append(chunk) }
                guard data.count <= 16384, error == nil else { self.close(id); return }
                guard let raw = String(data: data, encoding: .utf8) else { self.close(id); return }
                if !raw.contains("\r\n\r\n") {
                    if done { self.close(id) } else { self.read(connection, id: id, accumulated: data) }
                    return
                }
                let first = raw.components(separatedBy: "\r\n")[0].split(separator: " ")
                var accepted = false
                if first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"),
                   let port = self.listener?.port,
                   let url = URL(string: "http://127.0.0.1:\(port.rawValue)" + String(first[1])),
                   url.path == "/auth/callback" { accepted = self.accept?(url) ?? false }
                let body = accepted ? "授权回调已收到。请点“完成”返回 App。" : "此登录回调无效，请返回 App 重新登录。"
                let bytes = Data(body.utf8)
                let header = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(bytes.count)\r\n\r\n"
                connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in self?.close(id) }
                })
            }
        }
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
