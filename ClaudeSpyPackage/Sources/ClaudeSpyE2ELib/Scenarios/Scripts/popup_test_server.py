"""
popup_test_server.py — Tiny HTTP server for the popup-return E2E scenario.

Serves two pages on http://127.0.0.1:9876:
- /parent : huge centered link with target="_blank" pointing to /popup
- /popup  : static "POPUP PAGE" content

Both pages have stable <title> values ("Parent" / "Popup") so the in-app
browser tab strip's accessibility label ("Browser tab: <title>") is
predictable for the scenario's element queries.

Prints a single "READY 9876" line on startup so the scenario can poll the
captured pane content to confirm the server is up before proceeding.
"""
import http.server
import socketserver
import sys

PORT = 9876

PARENT_HTML = b"""<!doctype html>
<html><head><title>Parent</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; font-family: -apple-system, sans-serif; }
  body { display: flex; align-items: center; justify-content: center; background: #f0f0f0; }
  a.popup-link {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 80%;
    height: 70vh;
    font-size: 48px;
    color: white;
    background: #0066cc;
    text-decoration: none;
    border-radius: 16px;
  }
</style></head>
<body>
  <a class="popup-link" href="/popup" target="_blank">OPEN POPUP IN NEW TAB</a>
</body></html>
"""

POPUP_HTML = b"""<!doctype html>
<html><head><title>Popup</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; font-family: -apple-system, sans-serif; }
  body { display: flex; align-items: center; justify-content: center; background: #d4f5d4; }
  h1 { font-size: 72px; color: #003300; margin: 0; }
</style></head>
<body>
  <h1>POPUP PAGE</h1>
</body></html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/parent":
            body = PARENT_HTML
        elif self.path == "/popup":
            body = POPUP_HTML
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args, **kwargs):
        pass


def main():
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        sys.stdout.write(f"READY {PORT}\n")
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
