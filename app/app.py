#!/usr/bin/env python3
"""Minimal zero-dependency HTTP app for the ECS Fargate blue/green demo.

Behaviour is driven entirely by environment variables baked into the image:
  APP_VERSION  version string returned by GET /            (default "v0")
  HEALTHY      "true"  -> GET /health returns 200 OK
               "false" -> GET /health returns 500          (the "broken" v3)
  PORT         listen port                                  (default 8080)
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_VERSION = os.environ.get("APP_VERSION", "v0")
HEALTHY = os.environ.get("HEALTHY", "true").lower() == "true"
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload, content_type="application/json"):
        body = payload.encode() if isinstance(payload, str) else payload
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            if HEALTHY:
                self._send(200, "OK\n", "text/plain")
            else:
                # Intentionally broken release used to trigger CodeDeploy rollback.
                self._send(500, "unhealthy\n", "text/plain")
        elif self.path == "/":
            self._send(200, json.dumps({"version": APP_VERSION}) + "\n")
        else:
            self._send(404, json.dumps({"error": "not found"}) + "\n")

    def log_message(self, fmt, *args):
        # Log to stdout so the awslogs driver ships it to CloudWatch.
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    print(f"starting app version={APP_VERSION} healthy={HEALTHY} port={PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
