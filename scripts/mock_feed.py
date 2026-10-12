#!/usr/bin/env python3
"""Local stand-in for the ADS-B API, used to test error handling.
Usage: mock_feed.py PORT MODE   (MODE: 500 | 429 | garbage | empty | slow)"""
import http.server, sys, time

PORT, MODE = int(sys.argv[1]), sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if MODE in ("500", "429"):
            self.send_response(int(MODE)); self.end_headers(); self.wfile.write(b"error"); return
        if MODE == "slow":
            time.sleep(30)
        body = b"<html>not json</html>" if MODE == "garbage" else b'{"ac":[],"msg":"No error","now":%d,"total":0}' % int(time.time() * 1000)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
