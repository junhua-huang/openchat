#!/usr/bin/env python3
"""Read-only availability probe using the app's actual registry and MCP clients.

No AI key or MCP credentials; no tools/call is issued. External availability is
separate from deterministic XCTest checks.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
stub = '''import Foundation
enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
'''
wire = (root / "Core/ResponsesClient.swift").read_text()
wire = wire[wire.index("struct SSEParser"):]
main = '''
@main enum MCPProbe {
    @MainActor static func main() async {
        var failed = false
        do {
            let page = try await MCPRegistryClient().search("context7")
            guard page.entries.contains(where: { $0.endpoint == "https://mcp.context7.com/mcp" }) else {
                throw AppFailure.message("Registry did not return the expected remote server.")
            }
            print("Live MCP Registry passed: compatible results=\\(page.entries.filter(\\.canConnect).count)")
        } catch { failed = true; print("Live MCP Registry unavailable: " + error.localizedDescription) }
        for listing in MCPRegistryClient.recommendations.prefix(2) {
            guard let server = listing.server else { failed = true; continue }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 35
            let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
            let client = MCPClient(server: server, session: session)
            do {
                let tools = try await client.listTools()
                await client.disconnect()
                guard !tools.isEmpty else { throw AppFailure.message("Empty remote tool catalog") }
                print("Live MCP catalog passed: \\(listing.title), tools=\\(tools.count)")
            } catch { failed = true; await client.disconnect(); print("Live MCP catalog unavailable: " + listing.title + ": " + error.localizedDescription) }
            session.invalidateAndCancel()
        }
        if failed { exit(1) }
    }
}
'''
sources = ["Core/BoundedHTTP.swift", "Core/WebSearchClient.swift", "Core/ToolModels.swift", "Core/MCPClient.swift", "Core/MCPRegistry.swift"]
source = stub + "\n".join((root / path).read_text() for path in sources) + wire + main
with tempfile.TemporaryDirectory(prefix="openchat-mcp-") as folder:
    file = Path(folder, "MCPProbe.swift"); file.write_text(source)
    binary = Path(folder, "MCPProbe")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(file), "-o", str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=120)
