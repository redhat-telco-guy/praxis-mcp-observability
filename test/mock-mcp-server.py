#!/usr/bin/env python3
"""
Mock MCP server for testing Praxis MCP metrics.

Responds to MCP JSON-RPC methods:
  - server/discover  → returns capabilities
  - tools/list       → returns a static tool catalog
  - tools/call       → simulates tool execution with configurable latency/errors

Usage:
  python3 mock-mcp-server.py [--port 3001] [--error-rate 0.2] [--latency-ms 100]

The server listens on the given port and responds to POST /mcp.
"""

import argparse
import json
import random
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

# ── Configuration (set via CLI args) ──
ERROR_RATE = 0.0
LATENCY_MS = 50

TOOLS = [
    {
        "name": "get_weather",
        "description": "Get current weather for a city",
        "inputSchema": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
    {
        "name": "forecast",
        "description": "Get 5-day weather forecast",
        "inputSchema": {
            "type": "object",
            "properties": {
                "city": {"type": "string"},
                "days": {"type": "integer"},
            },
        },
    },
    {
        "name": "search_repos",
        "description": "Search GitHub repositories",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
]


def jsonrpc_response(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def jsonrpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


class McpHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/mcp":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            req = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error": "invalid JSON"}')
            return

        method = req.get("method", "")
        req_id = req.get("id", 1)
        params = req.get("params", {})

        if method == "server/discover":
            resp = jsonrpc_response(req_id, {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "mock-mcp", "version": "1.0.0"},
            })
        elif method == "tools/list":
            resp = jsonrpc_response(req_id, {"tools": TOOLS})
        elif method == "tools/call":
            tool_name = params.get("name", "unknown")
            # Simulate latency
            time.sleep(LATENCY_MS / 1000.0)
            # Simulate errors
            if random.random() < ERROR_RATE:
                resp = jsonrpc_error(req_id, -32000, f"Tool '{tool_name}' failed (simulated)")
            else:
                resp = jsonrpc_response(req_id, {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps({
                                "tool": tool_name,
                                "status": "ok",
                                "data": {"temp": 72, "unit": "F", "city": params.get("arguments", {}).get("city", "unknown")},
                            }),
                        }
                    ]
                })
        elif method == "initialize":
            resp = jsonrpc_response(req_id, {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "mock-mcp", "version": "1.0.0"},
            })
        else:
            resp = jsonrpc_error(req_id, -32601, f"Method not found: {method}")

        response_body = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    def log_message(self, format, *args):
        print(f"[mock-mcp] {args[0]}")


def main():
    parser = argparse.ArgumentParser(description="Mock MCP server for Praxis testing")
    parser.add_argument("--port", type=int, default=3001, help="Port to listen on (default: 3001)")
    parser.add_argument("--error-rate", type=float, default=0.0, help="Fraction of tools/call that fail (default: 0.0)")
    parser.add_argument("--latency-ms", type=int, default=50, help="Simulated tool latency in ms (default: 50)")
    args = parser.parse_args()

    global ERROR_RATE, LATENCY_MS
    ERROR_RATE = args.error_rate
    LATENCY_MS = args.latency_ms

    server = HTTPServer(("127.0.0.1", args.port), McpHandler)
    print(f"[mock-mcp] Listening on 127.0.0.1:{args.port}")
    print(f"[mock-mcp] Error rate: {ERROR_RATE}, Latency: {LATENCY_MS}ms")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock-mcp] Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
