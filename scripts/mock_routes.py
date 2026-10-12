#!/usr/bin/env python3
"""Stand-in for FlightAware AeroAPI /flights/{ident}, to test the route pipeline without a key.
Every ident is reported as an en-route ORD→SFO flight. Usage: mock_routes.py PORT"""
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("x-apikey") != "mock-key":
            self.send_response(401); self.end_headers(); return
        ident = self.path.split("/flights/")[-1].split("?")[0]
        body = {"flights": [{"ident": ident, "actual_off": "2026-10-12T01:00:00Z", "actual_on": None,
                 "origin": {"code": "KORD", "code_iata": "ORD", "code_icao": "KORD", "name": "Chicago O'Hare", "city": "Chicago"},
                 "destination": {"code": "KSFO", "code_iata": "SFO", "code_icao": "KSFO", "name": "San Francisco Intl", "city": "San Francisco"}}]}
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
