#!/usr/bin/env python3
"""macOS-only loopback smoke test: URLSession exposes decoded digest bytes.

Uses only the checked-in synthetic download fixture, a temporary Swift binary,
and an ephemeral 127.0.0.1 HTTP port. No app state or database is opened.
"""
import gzip
import http.server
import pathlib
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "docs/sync/v2/fixtures/canonical/download-page.json"
ENCODED = gzip.compress(FIXTURE.read_bytes(), mtime=0)
ACCEPT_ENCODINGS = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ACCEPT_ENCODINGS.append(self.headers.get("Accept-Encoding", ""))
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.fuminiwa.sync.v2+jcs")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(ENCODED)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(ENCODED)

    def log_message(self, *args):
        pass


SWIFT = '''
import Foundation
import CryptoKit
@main struct Verify {
    static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        precondition(url.host == "127.0.0.1")
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(from: url)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(bytes == expected, "URLSession did not return decoded bytes")
        precondition(SHA256.hash(data: bytes) == SHA256.hash(data: expected))
        print("PASS: URLSession gzip bytes and SHA-256 match the canonical fixture (\\(bytes.count) decoded bytes)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="fuminiwa-urlsession-gzip-") as scratch:
    scratch = pathlib.Path(scratch)
    source = scratch / "Verify.swift"
    binary = scratch / "verify"
    source.write_text(SWIFT)
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(scratch / "cache"),
        str(source), "-o", str(binary),
    ], check=True)
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            subprocess.run([
                str(binary), f"http://127.0.0.1:{server.server_port}/fixture", str(FIXTURE)
            ], check=True, timeout=30)
        finally:
            server.shutdown()
            thread.join()
    assert len(ACCEPT_ENCODINGS) == 1 and "gzip" in ACCEPT_ENCODINGS[0].lower()
    print("PASS: URLSession negotiated gzip via Accept-Encoding")
