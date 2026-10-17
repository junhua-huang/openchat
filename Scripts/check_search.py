#!/usr/bin/env python3
"""Exercise the actual Foundation search client without an AI token or API key.

Public search can be blocked by runner networks or provider challenges. Keep
this availability probe separate from the deterministic XCTest gate.
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
main = '''
@main enum SearchProbe {
    static func main() async throws {
        let response = try await WebSearchClient().search(query: "OpenAI API documentation", freshness: .any, count: 3)
        guard !response.results.isEmpty else { throw AppFailure.message("Public search returned no results on this runner.") }
        print("Live public search passed: provider=\\(response.provider), results=\\(response.results.count)")
        for result in response.results {
            guard let url = WebSearchClient.resultURL(result.url), !result.title.isEmpty else {
                throw AppFailure.message("Search returned an invalid source.")
            }
            print("Source host: " + (url.host ?? "invalid"))
        }
    }
}
'''
source = stub + (root / "Core/BoundedHTTP.swift").read_text() + (root / "Core/WebSearchClient.swift").read_text() + main
with tempfile.TemporaryDirectory(prefix="openchat-search-") as folder:
    file = Path(folder, "SearchProbe.swift"); file.write_text(source)
    binary = Path(folder, "SearchProbe")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(file), "-o", str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=90)
