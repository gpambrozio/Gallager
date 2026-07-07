"""
download_test_server.py — Tiny HTTP server for the browser downloads E2E scenario.

Serves on http://127.0.0.1:9877:
- /       : "Download Test" page with one huge DOWNLOAD-REPORT link so a
            fixed-pixel click reliably lands on it (same drift-tolerant
            big-target trick as popup_test_server.py / link_block.py)
- /report : text/plain served with `Content-Disposition: attachment` so the
            in-app browser converts the navigation into a WKDownload named
            report.txt

The page <title> is stable ("Download Test") so the browser tab strip's
accessibility label ("Browser tab: <title>") is predictable for element
queries, and the report body is deterministic so the scenario can assert
the file's on-disk contents.

Prints a single "READY 9877" line on startup so the scenario can poll the
captured pane content to confirm the server is up before proceeding.
"""
import http.server
import sys

PORT = 9877

PAGE_HTML = b"""<!doctype html>
<html><head><title>Download Test</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; font-family: -apple-system, sans-serif; }
  body { display: flex; flex-direction: column; background: #f0f0f0; }
  h1 { font-size: 32px; margin: 16px 24px; }
  a.download-link {
    display: flex;
    align-items: center;
    justify-content: center;
    margin: 0 24px;
    height: 60vh;
    font-size: 48px;
    color: white;
    background: #0a7d40;
    text-decoration: none;
    border-radius: 16px;
  }
</style></head>
<body>
  <h1>Download test page</h1>
  <a class="download-link" href="/report">DOWNLOAD-REPORT</a>
</body></html>
"""

REPORT_BODY = b"attachment download test contents\n" * 10


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(PAGE_HTML)))
            self.end_headers()
            self.wfile.write(PAGE_HTML)
        elif self.path == "/report":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Disposition", 'attachment; filename="report.txt"')
            self.send_header("Content-Length", str(len(REPORT_BODY)))
            self.end_headers()
            self.wfile.write(REPORT_BODY)
        else:
            self.send_error(404)

    def log_message(self, *args, **kwargs):
        pass


def main():
    # Threaded, unlike popup_test_server.py: converting a navigation into a
    # WKDownload opens a second connection while WebKit still holds the
    # original navigation's connection — a single-threaded server deadlocks
    # and the download never starts.
    with http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler) as httpd:
        sys.stdout.write(f"READY {PORT}\n")
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
