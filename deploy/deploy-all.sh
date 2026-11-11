#!/usr/bin/env bash
#
# deploy-all.sh -- Single-file OCP deployment for Praxis MCP Metrics
#
# Embeds all required files inline so you only need: bash deploy-all.sh
#
# Architecture (Red Hat / OCP-native):
#   AI Agent -> OCP Route (HAProxy) -> Praxis AI Gateway -> MCP Servers
#                                          |
#                                     Prometheus (ServiceMonitor)
#                                          |
#                                     Grafana Dashboard
#
# Deploys:
#   1. Three mock MCP servers (weather, calculator, translator)
#   2. Praxis config with 3 backend clusters + OCP Route
#   3. ServiceMonitor + PrometheusRule for Prometheus integration
#   4. Grafana dashboard JSON (importable into OCP monitoring)
#   5. Interactive demo dashboard (Red Hat httpd -- dev/test tool only)
#
# Prerequisites:
#   - oc CLI logged into your OCP cluster
#   - Praxis image already built (from run-all-ocp.sh)
#   - User workload monitoring enabled (optional, for Prometheus tab)
#
# Usage:
#   bash deploy-all.sh
#
set -euo pipefail
PROJECT="${PROJECT:-praxis-mcp-test}"
_DEPLOY_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_DEPLOY_TMPDIR"' EXIT

# ======== Embedded files ========
cat > "$_DEPLOY_TMPDIR/multi-mcp-servers.yaml" << 'EOF_MCP_SERVERS'
# ============================================================
#  Three mock MCP servers — Weather, Calculator, Translator
#  Each is a ConfigMap (Python script) + Deployment + Service
# ============================================================

# ── Weather MCP ──────────────────────────────────────────────
apiVersion: v1
kind: ConfigMap
metadata:
  name: weather-mcp-script
  labels:
    app: weather-mcp
data:
  server.py: |
    #!/usr/bin/env python3
    """Mock Weather MCP server — get_weather / forecast tools."""
    import json, random, time
    from http.server import HTTPServer, BaseHTTPRequestHandler

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
            "description": "Get multi-day weather forecast",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "city": {"type": "string"},
                    "days": {"type": "integer"},
                },
                "required": ["city"],
            },
        },
    ]

    CONDITIONS = ["sunny", "partly cloudy", "cloudy", "rainy", "stormy", "windy", "foggy"]

    def handle_rpc(body):
        rid = body.get("id")
        method = body.get("method", "")
        params = body.get("params", {})

        if method == "initialize":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "weather-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "server/discover":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "weather-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

        if method == "tools/call":
            tool = params.get("name", "")
            args = params.get("arguments", {})
            # Simulate 50-150ms latency
            time.sleep(random.uniform(0.05, 0.15))

            if tool == "get_weather":
                city = args.get("city", "Unknown")
                result = {
                    "content": [{"type": "text", "text": json.dumps({
                        "city": city,
                        "temperature": random.randint(55, 95),
                        "conditions": random.choice(CONDITIONS),
                        "humidity": random.randint(20, 80),
                        "wind_mph": random.randint(2, 25),
                    })}]
                }
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            if tool == "forecast":
                city = args.get("city", "Unknown")
                days = min(args.get("days", 5), 7)
                forecast = []
                for d in range(days):
                    forecast.append({
                        "day": d + 1,
                        "high": random.randint(65, 95),
                        "low": random.randint(40, 65),
                        "conditions": random.choice(CONDITIONS),
                    })
                result = {"content": [{"type": "text", "text": json.dumps({"city": city, "forecast": forecast})}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown tool: {tool}"}}

        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown method: {method}"}}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            resp = handle_rpc(body)
            out = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"weather-mcp OK\n")

        def log_message(self, fmt, *args):
            pass  # quiet

    print("weather-mcp listening on :3001")
    HTTPServer(("0.0.0.0", 3001), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: weather-mcp
  labels:
    app: weather-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: weather-mcp
  template:
    metadata:
      labels:
        app: weather-mcp
    spec:
      containers:
        - name: server
          image: python:3.11-alpine
          command: ["python3", "/app/server.py"]
          ports:
            - containerPort: 3001
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: script
              mountPath: /app
              readOnly: true
      volumes:
        - name: script
          configMap:
            name: weather-mcp-script
---
apiVersion: v1
kind: Service
metadata:
  name: weather-mcp
  labels:
    app: weather-mcp
spec:
  selector:
    app: weather-mcp
  ports:
    - port: 3001
      targetPort: 3001
      name: mcp

# ── Calculator MCP ───────────────────────────────────────────
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: calculator-mcp-script
  labels:
    app: calculator-mcp
data:
  server.py: |
    #!/usr/bin/env python3
    """Mock Calculator MCP server — add / multiply / factorial tools."""
    import json, math, time, random
    from http.server import HTTPServer, BaseHTTPRequestHandler

    TOOLS = [
        {
            "name": "add",
            "description": "Add two numbers",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "a": {"type": "number"},
                    "b": {"type": "number"},
                },
                "required": ["a", "b"],
            },
        },
        {
            "name": "multiply",
            "description": "Multiply two numbers",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "a": {"type": "number"},
                    "b": {"type": "number"},
                },
                "required": ["a", "b"],
            },
        },
        {
            "name": "factorial",
            "description": "Compute factorial of n (max 20)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "n": {"type": "integer"},
                },
                "required": ["n"],
            },
        },
    ]

    def handle_rpc(body):
        rid = body.get("id")
        method = body.get("method", "")
        params = body.get("params", {})

        if method == "initialize":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "calculator-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "server/discover":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "calculator-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

        if method == "tools/call":
            tool = params.get("name", "")
            args = params.get("arguments", {})
            # Near-instant: 5-20ms
            time.sleep(random.uniform(0.005, 0.02))

            if tool == "add":
                a, b = args.get("a", 0), args.get("b", 0)
                result = {"content": [{"type": "text", "text": json.dumps({"result": a + b})}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            if tool == "multiply":
                a, b = args.get("a", 0), args.get("b", 0)
                result = {"content": [{"type": "text", "text": json.dumps({"result": a * b})}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            if tool == "factorial":
                n = min(max(args.get("n", 0), 0), 20)
                result = {"content": [{"type": "text", "text": json.dumps({"result": math.factorial(n)})}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown tool: {tool}"}}

        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown method: {method}"}}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            resp = handle_rpc(body)
            out = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"calculator-mcp OK\n")

        def log_message(self, fmt, *args):
            pass

    print("calculator-mcp listening on :3001")
    HTTPServer(("0.0.0.0", 3001), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calculator-mcp
  labels:
    app: calculator-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: calculator-mcp
  template:
    metadata:
      labels:
        app: calculator-mcp
    spec:
      containers:
        - name: server
          image: python:3.11-alpine
          command: ["python3", "/app/server.py"]
          ports:
            - containerPort: 3001
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: script
              mountPath: /app
              readOnly: true
      volumes:
        - name: script
          configMap:
            name: calculator-mcp-script
---
apiVersion: v1
kind: Service
metadata:
  name: calculator-mcp
  labels:
    app: calculator-mcp
spec:
  selector:
    app: calculator-mcp
  ports:
    - port: 3001
      targetPort: 3001
      name: mcp

# ── Translator MCP ───────────────────────────────────────────
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: translator-mcp-script
  labels:
    app: translator-mcp
data:
  server.py: |
    #!/usr/bin/env python3
    """Mock Translator MCP server — translate / detect_language tools."""
    import json, time, random
    from http.server import HTTPServer, BaseHTTPRequestHandler

    TOOLS = [
        {
            "name": "translate",
            "description": "Translate text between languages",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "from_lang": {"type": "string"},
                    "to_lang": {"type": "string"},
                },
                "required": ["text", "to_lang"],
            },
        },
        {
            "name": "detect_language",
            "description": "Detect the language of input text",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                },
                "required": ["text"],
            },
        },
    ]

    LANG_NAMES = {"en": "English", "es": "Spanish", "fr": "French", "de": "German", "ja": "Japanese", "zh": "Chinese", "ko": "Korean", "pt": "Portuguese"}

    def handle_rpc(body):
        rid = body.get("id")
        method = body.get("method", "")
        params = body.get("params", {})

        if method == "initialize":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "translator-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "server/discover":
            return {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "translator-mcp", "version": "1.0.0"}, "capabilities": {"tools": {}}}}

        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

        if method == "tools/call":
            tool = params.get("name", "")
            args = params.get("arguments", {})
            # Simulate API latency: 200-500ms
            time.sleep(random.uniform(0.2, 0.5))

            if tool == "translate":
                text = args.get("text", "")
                from_lang = args.get("from_lang", "en")
                to_lang = args.get("to_lang", "es")
                to_name = LANG_NAMES.get(to_lang, to_lang)
                translated = f"[{to_name}] {text}"
                result = {"content": [{"type": "text", "text": json.dumps({
                    "translated": translated,
                    "from": from_lang,
                    "to": to_lang,
                    "characters": len(text),
                })}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            if tool == "detect_language":
                text = args.get("text", "")
                result = {"content": [{"type": "text", "text": json.dumps({
                    "language": "en",
                    "language_name": "English",
                    "confidence": round(random.uniform(0.85, 0.99), 3),
                    "characters_analyzed": len(text),
                })}]}
                return {"jsonrpc": "2.0", "id": rid, "result": result}

            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown tool: {tool}"}}

        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unknown method: {method}"}}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            resp = handle_rpc(body)
            out = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"translator-mcp OK\n")

        def log_message(self, fmt, *args):
            pass

    print("translator-mcp listening on :3001")
    HTTPServer(("0.0.0.0", 3001), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: translator-mcp
  labels:
    app: translator-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: translator-mcp
  template:
    metadata:
      labels:
        app: translator-mcp
    spec:
      containers:
        - name: server
          image: python:3.11-alpine
          command: ["python3", "/app/server.py"]
          ports:
            - containerPort: 3001
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: script
              mountPath: /app
              readOnly: true
      volumes:
        - name: script
          configMap:
            name: translator-mcp-script
---
apiVersion: v1
kind: Service
metadata:
  name: translator-mcp
  labels:
    app: translator-mcp
spec:
  selector:
    app: translator-mcp
  ports:
    - port: 3001
      targetPort: 3001
      name: mcp
EOF_MCP_SERVERS

cat > "$_DEPLOY_TMPDIR/servicemonitor.yaml" << 'EOF_SERVICEMONITOR'
# ============================================================
#  Prometheus integration for Praxis MCP metrics
#  Requires: OCP user workload monitoring enabled
#    oc apply -f cluster-monitoring-config.yaml  (see below)
# ============================================================

# ── ServiceMonitor — tells Prometheus to scrape Praxis ──────
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: praxis-ai-metrics
  labels:
    app: praxis-ai
spec:
  selector:
    matchLabels:
      app: praxis-ai
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
      metricRelabelings:
        # Keep only praxis_mcp_* metrics to avoid noise
        - sourceLabels: [__name__]
          regex: "praxis_mcp_.*"
          action: keep

---
# ── PrometheusRule — recording rules + alerts ───────────────
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: praxis-mcp-rules
  labels:
    app: praxis-ai
    role: recording-rules
spec:
  groups:
    # ── Recording rules ──
    - name: mcp.recording
      interval: 30s
      rules:
        # Overall MCP request rate (per second, 5m window)
        - record: mcp:requests:rate5m
          expr: sum(rate(praxis_mcp_requests_total[5m]))

        # MCP request rate by method
        - record: mcp:requests_by_method:rate5m
          expr: sum by (method) (rate(praxis_mcp_requests_total[5m]))

        # Tool call error ratio (0-1 scale)
        - record: mcp:tool_errors:ratio5m
          expr: |
            sum(rate(praxis_mcp_tool_calls_total{status="error"}[5m]))
            /
            clamp_min(sum(rate(praxis_mcp_tool_calls_total[5m])), 1)

        # Tool call rate by tool name
        - record: mcp:tool_calls_by_name:rate5m
          expr: sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))

        # Rejection rate (requests/sec)
        - record: mcp:rejections:rate5m
          expr: sum(rate(praxis_mcp_filter_rejections_total[5m]))

        # Rejection ratio vs total requests
        - record: mcp:rejection:ratio5m
          expr: |
            sum(rate(praxis_mcp_filter_rejections_total[5m]))
            /
            clamp_min(sum(rate(praxis_mcp_requests_total[5m])), 1)

    # ── Alerts ──
    - name: mcp.alerts
      rules:
        # High rejection rate — clients are misconfigured
        - alert: McpHighRejectionRate
          expr: mcp:rejection:ratio5m > 0.10
          for: 5m
          labels:
            severity: warning
            component: mcp-filter
          annotations:
            summary: "MCP filter rejection rate above 10%"
            description: >
              More than 10% of MCP requests are being rejected by the
              Praxis filter for the past 5 minutes. Current ratio:
              {{ $value | humanizePercentage }}. Check client headers
              and JSON-RPC payloads.

        # Tool call error spike — upstream MCP server issue
        - alert: McpToolCallErrorRate
          expr: mcp:tool_errors:ratio5m > 0.25
          for: 5m
          labels:
            severity: warning
            component: mcp-upstream
          annotations:
            summary: "MCP tool call error rate above 25%"
            description: >
              More than 25% of tool calls are returning errors from
              upstream MCP servers. Current error ratio:
              {{ $value | humanizePercentage }}. Investigate upstream
              server health.

        # No MCP traffic for 15 minutes (if previously active)
        - alert: McpNoTraffic
          expr: |
            sum(rate(praxis_mcp_requests_total[5m])) == 0
            and
            sum(increase(praxis_mcp_requests_total[1h])) > 0
          for: 15m
          labels:
            severity: info
            component: mcp-filter
          annotations:
            summary: "No MCP traffic for 15 minutes"
            description: >
              Praxis has received MCP traffic in the past hour but
              none in the last 15 minutes. This may indicate a client
              or network issue.

---
# ── Enable user workload monitoring (cluster-level) ─────────
# Apply this ONCE per cluster if not already enabled:
#
#   oc apply -f - <<EOF
#   apiVersion: v1
#   kind: ConfigMap
#   metadata:
#     name: cluster-monitoring-config
#     namespace: openshift-monitoring
#   data:
#     config.yaml: |
#       enableUserWorkload: true
#   EOF
#
# Then wait for prometheus-user-workload pods to start:
#   oc get pods -n openshift-user-workload-monitoring
#
# After that, praxis_mcp_* metrics appear in:
#   Observe → Metrics (OCP Console)
#
# Useful PromQL queries:
#
#   # Total MCP requests per second
#   sum(rate(praxis_mcp_requests_total[5m]))
#
#   # Requests broken down by method
#   sum by (method) (rate(praxis_mcp_requests_total[5m]))
#
#   # Tool calls per second by tool name
#   sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))
#
#   # Tool call error rate
#   sum(rate(praxis_mcp_tool_calls_total{status="error"}[5m]))
#   / sum(rate(praxis_mcp_tool_calls_total[5m]))
#
#   # Average tool call latency (from summary)
#   praxis_mcp_tool_call_duration_seconds{quantile="0.5"}
#
#   # p99 tool call latency
#   praxis_mcp_tool_call_duration_seconds{quantile="0.99"}
#
#   # Rejection rate by reason
#   sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))
EOF_SERVICEMONITOR

cat > "$_DEPLOY_TMPDIR/grafana-dashboard.json" << 'EOF_GRAFANA'
{
  "__inputs": [
    {
      "name": "DS_PROMETHEUS",
      "label": "Prometheus",
      "description": "Prometheus datasource for Praxis MCP metrics",
      "type": "datasource",
      "pluginId": "prometheus",
      "pluginName": "Prometheus"
    }
  ],
  "__requires": [
    { "type": "grafana", "id": "grafana", "name": "Grafana", "version": "9.0.0" },
    { "type": "datasource", "id": "prometheus", "name": "Prometheus", "version": "1.0.0" },
    { "type": "panel", "id": "stat", "name": "Stat", "version": "" },
    { "type": "panel", "id": "timeseries", "name": "Time series", "version": "" },
    { "type": "panel", "id": "table", "name": "Table", "version": "" }
  ],
  "id": null,
  "uid": "praxis-mcp-metrics",
  "title": "Praxis MCP Gateway - MCP Metrics",
  "description": "Operational dashboard for MCP protocol metrics exposed by the Praxis AI Gateway MCP filter.",
  "tags": ["praxis", "mcp", "ai-gateway"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "version": 1,
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "10s",
  "templating": { "list": [] },
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": { "type": "grafana", "uid": "-- Grafana --" },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "panels": [
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
      "id": 100,
      "title": "Overview",
      "type": "row"
    },
    {
      "id": 1,
      "title": "MCP Request Rate",
      "description": "Total MCP JSON-RPC requests per second across all methods.",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 4, "w": 5, "x": 0, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 100 },
              { "color": "red", "value": 500 }
            ]
          },
          "color": { "mode": "thresholds" }
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(praxis_mcp_requests_total[5m]))",
          "legendFormat": "",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 2,
      "title": "Tool Call Rate",
      "description": "Completed tool calls per second (tools/call that reached upstream).",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 4, "w": 5, "x": 5, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 50 },
              { "color": "red", "value": 200 }
            ]
          },
          "color": { "mode": "thresholds" }
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(praxis_mcp_tool_calls_total[5m]))",
          "legendFormat": "",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 3,
      "title": "Tool Error Rate",
      "description": "Percentage of tool calls returning errors from upstream MCP servers.",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 4, "w": 5, "x": 10, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "decimals": 1,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "#EAB839", "value": 5 },
              { "color": "red", "value": 25 }
            ]
          },
          "color": { "mode": "thresholds" },
          "noValue": "0%"
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(praxis_mcp_tool_calls_total{status=\"error\"}[5m])) / sum(rate(praxis_mcp_tool_calls_total[5m])) * 100",
          "legendFormat": "",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 4,
      "title": "Rejection Rate",
      "description": "Percentage of requests rejected by the MCP filter before reaching upstream.",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 4, "w": 5, "x": 15, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "decimals": 1,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "#EAB839", "value": 5 },
              { "color": "red", "value": 10 }
            ]
          },
          "color": { "mode": "thresholds" },
          "noValue": "0%"
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(praxis_mcp_filter_rejections_total[5m])) / sum(rate(praxis_mcp_requests_total[5m])) * 100",
          "legendFormat": "",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 5,
      "title": "P99 Latency",
      "description": "99th-percentile tool call round-trip time. Uses summary quantile (metrics crate default).",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 4, "w": 4, "x": 20, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "decimals": 3,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "#EAB839", "value": 0.5 },
              { "color": "red", "value": 2 }
            ]
          },
          "color": { "mode": "thresholds" },
          "noValue": "N/A"
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "histogram_quantile(0.99, sum(rate(praxis_mcp_tool_call_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "histogram p99",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        },
        {
          "refId": "B",
          "expr": "max(praxis_mcp_tool_call_duration_seconds{quantile=\"0.99\"})",
          "legendFormat": "summary p99",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 5 },
      "id": 104,
      "title": "Control Plane vs Data Plane",
      "type": "row"
    },
    {
      "id": 20,
      "title": "Control Plane Rate",
      "description": "Request rate for control plane methods: initialize, server/discover, tools/list, ping. These are handled by Praxis itself and may never reach upstream MCP servers.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 6 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "tools/list" },
            "properties": [{ "id": "color", "value": { "fixedColor": "#00bcd4", "mode": "fixed" } }]
          },
          {
            "matcher": { "id": "byName", "options": "initialize" },
            "properties": [{ "id": "color", "value": { "fixedColor": "#0097a7", "mode": "fixed" } }]
          },
          {
            "matcher": { "id": "byName", "options": "server/discover" },
            "properties": [{ "id": "color", "value": { "fixedColor": "#26c6da", "mode": "fixed" } }]
          },
          {
            "matcher": { "id": "byName", "options": "ping" },
            "properties": [{ "id": "color", "value": { "fixedColor": "#4dd0e1", "mode": "fixed" } }]
          }
        ]
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": ["lastNotNull"] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (method) (rate(praxis_mcp_requests_total{method=~\"initialize|server/discover|tools/list|ping\"}[5m]))",
          "legendFormat": "{{method}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 21,
      "title": "Data Plane Rate",
      "description": "Request rate for data plane methods (tools/call) — these flow through the full pipeline to upstream MCP servers. Second query shows breakdown by tool name.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 6 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "tools/call" },
            "properties": [{ "id": "color", "value": { "fixedColor": "#ff9800", "mode": "fixed" } }]
          }
        ]
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": ["lastNotNull"] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (method) (rate(praxis_mcp_requests_total{method=\"tools/call\"}[5m]))",
          "legendFormat": "{{method}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        },
        {
          "refId": "B",
          "expr": "sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))",
          "legendFormat": "{{tool}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 22,
      "title": "Data Plane %",
      "description": "Percentage of traffic that is data plane (tools/call). High ratio means agents are actively executing tools, not just discovering.",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 6 },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "decimals": 1,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "#00bcd4", "value": null },
              { "color": "#ff9800", "value": 50 },
              { "color": "#f57c00", "value": 80 }
            ]
          },
          "color": { "mode": "thresholds" },
          "noValue": "N/A"
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto"
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(praxis_mcp_requests_total{method=\"tools/call\"}[5m])) / sum(rate(praxis_mcp_requests_total[5m])) * 100",
          "legendFormat": "",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 14 },
      "id": 101,
      "title": "Traffic",
      "type": "row"
    },
    {
      "id": 6,
      "title": "Requests by Method",
      "description": "MCP request rate broken down by JSON-RPC method (tools/call, tools/list, etc.).",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 15 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": [] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (method) (rate(praxis_mcp_requests_total[5m]))",
          "legendFormat": "{{method}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 7,
      "title": "Tool Calls by Tool",
      "description": "Completed tool call rate per tool name across all clusters.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 15 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": [] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))",
          "legendFormat": "{{tool}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 8,
      "title": "Tool Calls by Cluster",
      "description": "Completed tool call rate per upstream MCP server cluster.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 15 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": [] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (cluster) (rate(praxis_mcp_tool_calls_total[5m]))",
          "legendFormat": "{{cluster}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 23 },
      "id": 102,
      "title": "Latency",
      "type": "row"
    },
    {
      "id": 9,
      "title": "Tool Call Latency Quantiles",
      "description": "P50, P90, P99 round-trip latency for tool calls (summary quantiles from metrics crate).",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 10,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "p99" },
            "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
          },
          {
            "matcher": { "id": "byName", "options": "p90" },
            "properties": [{ "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }]
          },
          {
            "matcher": { "id": "byName", "options": "p50" },
            "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }]
          }
        ]
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": ["lastNotNull"] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "praxis_mcp_tool_call_duration_seconds{quantile=\"0.5\"}",
          "legendFormat": "p50",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        },
        {
          "refId": "B",
          "expr": "praxis_mcp_tool_call_duration_seconds{quantile=\"0.9\"}",
          "legendFormat": "p90",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        },
        {
          "refId": "C",
          "expr": "praxis_mcp_tool_call_duration_seconds{quantile=\"0.99\"}",
          "legendFormat": "p99",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 10,
      "title": "Latency by Tool (p50)",
      "description": "Median round-trip latency per tool name — compare performance across tools.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 24 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": ["lastNotNull"] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "praxis_mcp_tool_call_duration_seconds{quantile=\"0.5\"}",
          "legendFormat": "{{tool}} p50",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 32 },
      "id": 103,
      "title": "Errors & Rejections",
      "type": "row"
    },
    {
      "id": 11,
      "title": "Rejections by Reason",
      "description": "Rate of filter rejections broken down by reason (invalid_params, header_mismatch, missing_header).",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 33 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "normal" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": [] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))",
          "legendFormat": "{{reason}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 12,
      "title": "Tool Errors by Tool",
      "description": "Rate of tool calls returning error status, per tool name.",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 33 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 15,
            "gradientMode": "scheme",
            "showPoints": "auto",
            "pointSize": 5,
            "stacking": { "mode": "none" },
            "axisPlacement": "auto",
            "spanNulls": true
          },
          "color": { "mode": "palette-classic" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "calcs": [] },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (tool) (rate(praxis_mcp_tool_calls_total{status=\"error\"}[5m]))",
          "legendFormat": "{{tool}}",
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    },
    {
      "id": 13,
      "title": "Rejection Details",
      "description": "Current rejection counts by method and reason.",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 33 },
      "fieldConfig": {
        "defaults": {},
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Time" },
            "properties": [{ "id": "custom.hidden", "value": true }]
          },
          {
            "matcher": { "id": "byName", "options": "Value" },
            "properties": [{ "id": "displayName", "value": "Count" }]
          }
        ]
      },
      "options": {
        "showHeader": true,
        "sortBy": [{ "displayName": "Count", "desc": true }],
        "footer": { "show": false }
      },
      "transformations": [
        {
          "id": "labelsToFields",
          "options": { "mode": "columns", "keepLabels": ["method", "reason"] }
        }
      ],
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (method, reason) (praxis_mcp_filter_rejections_total)",
          "legendFormat": "",
          "format": "table",
          "instant": true,
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" }
        }
      ]
    }
  ]
}
EOF_GRAFANA

cat > "$_DEPLOY_TMPDIR/dashboard.html" << 'EOF_DASHBOARD_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Praxis MCP Metrics Dashboard</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{
  --bg:#0f1117;--surface:#181b24;--surface2:#1e222d;--border:#2a2f3c;
  --text:#e2e4ea;--text-dim:#8b90a0;--accent:#6c8cff;--accent-dim:rgba(108,140,255,.12);
  --green:#34d399;--green-dim:rgba(52,211,153,.12);
  --red:#f87171;--red-dim:rgba(248,113,113,.12);
  --amber:#fbbf24;--amber-dim:rgba(251,191,36,.12);
  --purple:#a78bfa;--purple-dim:rgba(167,139,250,.12);
  --mono:'Menlo','Consolas','JetBrains Mono',monospace;
  --sans:system-ui,-apple-system,sans-serif;
}
html,body{height:100%;font-family:var(--sans);background:var(--bg);color:var(--text)}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}

/* ── Header ── */
.header{padding:20px 32px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px}
.header h1{font-size:18px;font-weight:600;letter-spacing:-.3px}
.header .dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.header .dot.ok{background:var(--green);box-shadow:0 0 6px var(--green)}
.header .dot.err{background:var(--red)}
.header .sub{color:var(--text-dim);font-size:13px;margin-left:auto}

/* ── Tabs ── */
.tab-bar{display:flex;border-bottom:1px solid var(--border);padding:0 32px;gap:0}
.tab-btn{padding:12px 24px;font-family:var(--sans);font-size:14px;font-weight:500;color:var(--text-dim);
  background:none;border:none;border-bottom:2px solid transparent;cursor:pointer;transition:.15s}
.tab-btn:hover{color:var(--text)}
.tab-btn.active{color:var(--accent);border-bottom-color:var(--accent)}
.tab-content{display:none;padding:28px 32px;overflow-y:auto;height:calc(100vh - 110px)}
.tab-content.active{display:block}

/* ── Cards ── */
.card-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:28px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:18px}
.card .lbl{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--text-dim);margin-bottom:6px}
.card .val{font-family:var(--mono);font-size:26px;font-weight:700}
.card .sub{font-size:11px;color:var(--text-dim);margin-top:4px}
.tag{display:inline-block;font-size:10px;font-family:var(--mono);padding:2px 7px;border-radius:3px;margin-top:6px;margin-right:3px}
.tag-b{background:var(--accent-dim);color:var(--accent)}
.tag-g{background:var(--green-dim);color:var(--green)}
.tag-r{background:var(--red-dim);color:var(--red)}
.tag-a{background:var(--amber-dim);color:var(--amber)}
.tag-p{background:var(--purple-dim);color:var(--purple)}

/* ── Bar chart ── */
.chart-box{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px;margin-bottom:14px}
.chart-box h3{font-size:14px;font-weight:600;margin-bottom:14px}
.bar-row{display:flex;align-items:center;gap:10px;margin-bottom:8px}
.bar-label{font-family:var(--mono);font-size:11px;color:var(--text-dim);width:180px;text-align:right;flex-shrink:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar-track{flex:1;height:22px;background:var(--bg);border-radius:3px;overflow:hidden}
.bar-fill{height:100%;border-radius:3px;transition:width .4s ease;min-width:2px}
.bar-val{font-family:var(--mono);font-size:11px;width:60px;text-align:right;flex-shrink:0}

/* ── Toolbar ── */
.toolbar{display:flex;align-items:center;gap:12px;margin-bottom:18px}
.btn{background:var(--accent);color:#fff;border:none;border-radius:6px;padding:8px 18px;font-family:var(--sans);font-size:13px;font-weight:500;cursor:pointer;transition:.15s}
.btn:hover{opacity:.85}.btn:active{transform:scale(.98)}
.btn-sm{padding:6px 14px;font-size:12px}
.btn-outline{background:transparent;border:1px solid var(--border);color:var(--text)}
.btn-outline:hover{border-color:var(--accent);background:var(--surface2)}
.btn-green{background:var(--green)}
.btn-amber{background:var(--amber);color:#000}
.btn-red{background:var(--red)}
.btn-purple{background:var(--purple)}
.ts{font-size:11px;color:var(--text-dim)}

/* ── Raw box ── */
.raw-box{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:14px;font-family:var(--mono);font-size:11px;line-height:1.8;color:var(--text-dim);max-height:260px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.raw-box .hl{color:var(--text)}.raw-box .hv{color:var(--green);font-weight:600}

/* ── Test Lab ── */
.server-section{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px;margin-bottom:16px}
.server-section h3{font-size:15px;font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:8px}
.server-section h3 .badge{font-size:10px;padding:2px 8px;border-radius:10px;font-weight:600}
.server-section .desc{font-size:12px;color:var(--text-dim);margin-bottom:14px}
.tool-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}
.tool-card{background:var(--surface2);border:1px solid var(--border);border-radius:8px;padding:14px}
.tool-card .tool-name{font-family:var(--mono);font-size:13px;font-weight:600;margin-bottom:8px}
.tool-card .inputs{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}
.tool-card input,.tool-card select{background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:5px 8px;color:var(--text);font-family:var(--mono);font-size:12px;width:100px}
.tool-card select{width:auto}
.tool-card .result{font-family:var(--mono);font-size:11px;margin-top:8px;padding:8px;background:var(--bg);border-radius:4px;max-height:80px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;display:none}
.tool-card .result.show{display:block}
.special-btns{display:flex;gap:10px;margin-top:16px}

/* ── Prometheus tab ── */
.prom-section{margin-bottom:28px}
.prom-section h3{font-size:16px;font-weight:600;margin-bottom:10px}
.prom-section p,.prom-section li{font-size:14px;color:var(--text);line-height:1.7}
.prom-section ol,.prom-section ul{padding-left:20px;margin-bottom:12px}
.prom-section li{margin-bottom:6px}
.query-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:14px;margin-bottom:10px;display:flex;align-items:flex-start;gap:12px}
.query-card .q{flex:1}
.query-card .q-label{font-size:13px;font-weight:600;margin-bottom:4px}
.query-card .q-code{font-family:var(--mono);font-size:12px;color:var(--accent);background:var(--bg);padding:8px 10px;border-radius:4px;word-break:break-all}
.query-card .copy-btn{background:var(--surface2);border:1px solid var(--border);border-radius:4px;padding:6px 10px;color:var(--text-dim);font-size:11px;cursor:pointer;white-space:nowrap}
.query-card .copy-btn:hover{border-color:var(--accent);color:var(--accent)}
.code-block{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:14px;font-family:var(--mono);font-size:11px;line-height:1.6;overflow-x:auto;color:var(--text-dim);margin-bottom:14px;white-space:pre;max-height:300px;overflow-y:auto}
.step-num{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:50%;background:var(--accent-dim);color:var(--accent);font-size:12px;font-weight:600;margin-right:8px;flex-shrink:0}

/* ── Architecture tab ── */
#arch-tab{padding:0;position:relative;height:calc(100vh - 110px)}
#three-canvas{width:100%;height:100%;display:block}
.arch-toolbar{position:absolute;top:16px;left:16px;display:flex;gap:8px;z-index:10}
.arch-tooltip{position:absolute;background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:12px 16px;max-width:280px;font-size:13px;line-height:1.6;pointer-events:none;z-index:20;display:none;box-shadow:0 8px 32px rgba(0,0,0,.5)}
.arch-tooltip h4{font-size:14px;font-weight:600;margin-bottom:4px}
.arch-tooltip p{color:var(--text-dim);font-size:12px}
.three-label{position:absolute;font-family:var(--sans);font-size:11px;font-weight:600;color:var(--text);pointer-events:none;text-align:center;white-space:nowrap;text-shadow:0 1px 4px rgba(0,0,0,.8);z-index:5}
.three-sublabel{font-size:9px;font-weight:400;color:var(--text-dim);display:block}

/* ── Plane indicators ── */
.plane-section{margin-bottom:24px}
.plane-header{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.plane-badge{font-size:11px;font-weight:700;padding:3px 10px;border-radius:4px;letter-spacing:.5px;font-family:var(--mono)}
.plane-badge.ctrl{background:rgba(0,188,212,.12);color:#00bcd4;border:1px solid rgba(0,188,212,.25)}
.plane-badge.data{background:rgba(255,152,0,.12);color:#ff9800;border:1px solid rgba(255,152,0,.25)}
.plane-title{font-size:15px;font-weight:600}
.plane-desc{font-size:12px;color:var(--text-dim);margin-left:auto}
.plane-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:20px}
.plane-card{background:var(--surface);border-radius:10px;padding:18px;position:relative;overflow:hidden}
.plane-card::before{content:'';position:absolute;top:0;left:0;right:0;height:3px}
.plane-card.ctrl::before{background:linear-gradient(90deg,#00bcd4,#0097a7)}
.plane-card.data::before{background:linear-gradient(90deg,#ff9800,#f57c00)}
.plane-card .lbl{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--text-dim);margin-bottom:6px}
.plane-card .val{font-family:var(--mono);font-size:24px;font-weight:700}
.plane-card .sub{font-size:11px;color:var(--text-dim);margin-top:4px}
.plane-card .methods{font-family:var(--mono);font-size:10px;color:var(--text-dim);margin-top:8px;line-height:1.6}
.metric-map{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px;margin-bottom:24px}
.metric-map h3{font-size:14px;font-weight:600;margin-bottom:14px}
.metric-map-grid{display:grid;grid-template-columns:1fr 120px 120px;gap:0;font-size:12px}
.metric-map-grid .mh{font-weight:600;color:var(--text-dim);text-transform:uppercase;font-size:10px;letter-spacing:.5px;padding:8px 12px;border-bottom:1px solid var(--border)}
.metric-map-grid .mc{padding:8px 12px;border-bottom:1px solid rgba(42,47,60,.4);font-family:var(--mono);font-size:11px}
.metric-map-grid .mc.name{color:var(--accent)}
.dot-ctrl{display:inline-block;width:8px;height:8px;border-radius:50%;background:#00bcd4;margin-right:4px}
.dot-data{display:inline-block;width:8px;height:8px;border-radius:50%;background:#ff9800;margin-right:4px}

/* ── 3D legend ── */
.arch-legend{position:absolute;bottom:16px;left:16px;background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:14px 18px;z-index:10;font-size:12px}
.arch-legend h4{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--text-dim);margin-bottom:8px}
.legend-row{display:flex;align-items:center;gap:8px;margin-bottom:5px}
.legend-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.legend-line{width:20px;height:3px;border-radius:2px;flex-shrink:0}

@media(max-width:900px){
  .card-grid{grid-template-columns:repeat(2,1fr)}
  .plane-grid{grid-template-columns:1fr}
  .tool-grid{grid-template-columns:1fr}
  .tab-btn{padding:10px 14px;font-size:13px}
  .tab-content{padding:16px}
}
</style>
</head>
<body>

<div class="header">
  <div class="dot ok" id="statusDot"></div>
  <h1>Praxis MCP Metrics</h1>
  <span class="sub">Live from OpenShift &middot; 3 MCP Servers</span>
</div>

<div class="tab-bar">
  <button class="tab-btn active" onclick="switchTab('metrics')">Metrics</button>
  <button class="tab-btn" onclick="switchTab('testlab')">Test Lab</button>
  <button class="tab-btn" onclick="switchTab('prometheus')">Prometheus</button>
  <button class="tab-btn" onclick="switchTab('architecture')">Architecture</button>
</div>

<!-- ════════════════════════════════════════════════ -->
<!-- TAB 1: METRICS                                  -->
<!-- ════════════════════════════════════════════════ -->
<div class="tab-content active" id="tab-metrics">

  <div class="card-grid">
    <div class="card">
      <div class="lbl">Total Requests</div>
      <div class="val" id="m-total-req">—</div>
      <div class="sub">All MCP JSON-RPC methods</div>
      <div id="m-req-tags"></div>
    </div>
    <div class="card">
      <div class="lbl">Tool Calls</div>
      <div class="val" id="m-total-tools">—</div>
      <div class="sub">Completed tools/call</div>
      <div id="m-tool-tags"></div>
    </div>
    <div class="card">
      <div class="lbl">Avg Latency</div>
      <div class="val" id="m-avg-lat">—</div>
      <div class="sub">Tool call round-trip</div>
      <div id="m-lat-tags"></div>
    </div>
    <div class="card">
      <div class="lbl">Rejections</div>
      <div class="val" id="m-total-rej">—</div>
      <div class="sub">Blocked by filter</div>
      <div id="m-rej-tags"></div>
    </div>
  </div>

  <div class="toolbar">
    <button class="btn" onclick="refreshMetrics()">Refresh</button>
    <span class="ts" id="lastUpdate"></span>
  </div>

  <!-- ── Control Plane vs Data Plane ── -->
  <div class="plane-grid">
    <div class="plane-card ctrl">
      <div class="lbl">Control Plane Traffic</div>
      <div class="val" id="m-ctrl-count">—</div>
      <div class="sub">Discovery, negotiation, capabilities</div>
      <div class="methods" id="m-ctrl-methods">initialize, server/discover, tools/list, ping</div>
    </div>
    <div class="plane-card data">
      <div class="lbl">Data Plane Traffic</div>
      <div class="val" id="m-data-count">—</div>
      <div class="sub">Tool execution, actual work</div>
      <div class="methods" id="m-data-methods">tools/call → upstream MCP servers</div>
    </div>
  </div>

  <!-- Metric → Plane mapping table -->
  <div class="metric-map">
    <h3>Which metric records what — and where</h3>
    <div class="metric-map-grid">
      <div class="mh">Metric</div>
      <div class="mh">Control</div>
      <div class="mh">Data</div>
      <div class="mc name">praxis_mcp_requests_total</div>
      <div class="mc"><span class="dot-ctrl"></span>Yes</div>
      <div class="mc"><span class="dot-data"></span>Yes</div>
      <div class="mc name">praxis_mcp_tool_calls_total</div>
      <div class="mc" style="color:var(--text-dim)">—</div>
      <div class="mc"><span class="dot-data"></span>Data only</div>
      <div class="mc name">praxis_mcp_tool_call_duration_seconds</div>
      <div class="mc" style="color:var(--text-dim)">—</div>
      <div class="mc"><span class="dot-data"></span>Data only</div>
      <div class="mc name">praxis_mcp_filter_rejections_total</div>
      <div class="mc"><span class="dot-ctrl"></span>Yes</div>
      <div class="mc"><span class="dot-data"></span>Yes</div>
    </div>
    <div style="font-size:12px;color:var(--text-dim);margin-top:12px;line-height:1.7">
      <strong style="color:var(--text)">Control plane</strong> requests (initialize, tools/list, server/discover) are handled by Praxis itself — they may never reach the upstream MCP server. Only <code style="font-family:var(--mono);color:var(--accent)">requests_total</code> fires.<br>
      <strong style="color:var(--text)">Data plane</strong> requests (tools/call) flow through the full pipeline: MCP Filter → Router → Load Balancer → upstream MCP server → response. All 4 metrics fire — <code style="font-family:var(--mono);color:var(--accent)">requests_total</code> on entry, <code style="font-family:var(--mono);color:var(--accent)">tool_calls_total</code> and <code style="font-family:var(--mono);color:var(--accent)">duration_seconds</code> on response.
    </div>
  </div>

  <div class="chart-box">
    <h3>Requests by Plane</h3>
    <div style="display:flex;gap:20px;margin-bottom:14px">
      <div style="flex:1"><div style="font-size:11px;font-weight:600;color:#00bcd4;margin-bottom:6px">CONTROL PLANE</div><div id="chart-ctrl"></div></div>
      <div style="flex:1"><div style="font-size:11px;font-weight:600;color:#ff9800;margin-bottom:6px">DATA PLANE</div><div id="chart-data"></div></div>
    </div>
  </div>

  <div class="chart-box"><h3>All Requests by Method</h3><div id="chart-req"></div></div>
  <div class="chart-box"><h3>Tool Calls by Name (Data Plane)</h3><div id="chart-tool"></div></div>
  <div class="chart-box"><h3>Latency Quantiles (Data Plane)</h3><div id="chart-lat"></div></div>

  <h3 style="font-size:14px;font-weight:600;margin:24px 0 10px">Raw Prometheus Output</h3>
  <div class="raw-box" id="rawMetrics">Click Refresh to load…</div>
</div>

<!-- ════════════════════════════════════════════════ -->
<!-- TAB 2: TEST LAB                                 -->
<!-- ════════════════════════════════════════════════ -->
<div class="tab-content" id="tab-testlab">

  <!-- Weather -->
  <div class="server-section">
    <h3><span class="badge" style="background:var(--green-dim);color:var(--green)">WEATHER</span> Weather MCP Server</h3>
    <div class="desc">Simulates an external weather API. 50-150 ms latency per call.</div>
    <div class="tool-grid">
      <div class="tool-card">
        <div class="tool-name">get_weather</div>
        <div class="inputs">
          <input id="w-city" placeholder="city" value="Austin">
        </div>
        <button class="btn btn-sm btn-green" onclick="sendTool('weather','get_weather',{city:v('w-city')},this)">Send</button>
        <div class="result" id="res-w-gw"></div>
      </div>
      <div class="tool-card">
        <div class="tool-name">forecast</div>
        <div class="inputs">
          <input id="w-fcity" placeholder="city" value="Tokyo">
          <select id="w-days"><option>3</option><option selected>5</option><option>7</option></select>
        </div>
        <button class="btn btn-sm btn-green" onclick="sendTool('weather','forecast',{city:v('w-fcity'),days:parseInt(v('w-days'))},this)">Send</button>
        <div class="result" id="res-w-fc"></div>
      </div>
    </div>
  </div>

  <!-- Calculator -->
  <div class="server-section">
    <h3><span class="badge" style="background:var(--amber-dim);color:var(--amber)">CALC</span> Calculator MCP Server</h3>
    <div class="desc">Pure compute — near-instant responses (5-20 ms).</div>
    <div class="tool-grid">
      <div class="tool-card">
        <div class="tool-name">add</div>
        <div class="inputs">
          <input id="c-a1" type="number" placeholder="a" value="42" style="width:60px">
          <input id="c-b1" type="number" placeholder="b" value="58" style="width:60px">
        </div>
        <button class="btn btn-sm btn-amber" onclick="sendTool('calculator','add',{a:+v('c-a1'),b:+v('c-b1')},this)">Send</button>
        <div class="result" id="res-c-add"></div>
      </div>
      <div class="tool-card">
        <div class="tool-name">multiply</div>
        <div class="inputs">
          <input id="c-a2" type="number" placeholder="a" value="7" style="width:60px">
          <input id="c-b2" type="number" placeholder="b" value="6" style="width:60px">
        </div>
        <button class="btn btn-sm btn-amber" onclick="sendTool('calculator','multiply',{a:+v('c-a2'),b:+v('c-b2')},this)">Send</button>
        <div class="result" id="res-c-mul"></div>
      </div>
      <div class="tool-card">
        <div class="tool-name">factorial</div>
        <div class="inputs">
          <input id="c-n" type="number" placeholder="n" value="10" style="width:60px">
        </div>
        <button class="btn btn-sm btn-amber" onclick="sendTool('calculator','factorial',{n:+v('c-n')},this)">Send</button>
        <div class="result" id="res-c-fac"></div>
      </div>
    </div>
  </div>

  <!-- Translator -->
  <div class="server-section">
    <h3><span class="badge" style="background:var(--purple-dim);color:var(--purple)">LANG</span> Translator MCP Server</h3>
    <div class="desc">Simulates a translation API. 200-500 ms latency (realistic for external LLM calls).</div>
    <div class="tool-grid">
      <div class="tool-card">
        <div class="tool-name">translate</div>
        <div class="inputs">
          <input id="t-text" placeholder="text" value="Hello world" style="width:140px">
          <input id="t-from" placeholder="from" value="en" style="width:40px">
          <input id="t-to" placeholder="to" value="es" style="width:40px">
        </div>
        <button class="btn btn-sm btn-purple" onclick="sendTool('translator','translate',{text:v('t-text'),from_lang:v('t-from'),to_lang:v('t-to')},this)">Send</button>
        <div class="result" id="res-t-tr"></div>
      </div>
      <div class="tool-card">
        <div class="tool-name">detect_language</div>
        <div class="inputs">
          <input id="t-det" placeholder="text" value="Bonjour le monde" style="width:180px">
        </div>
        <button class="btn btn-sm btn-purple" onclick="sendTool('translator','detect_language',{text:v('t-det')},this)">Send</button>
        <div class="result" id="res-t-dl"></div>
      </div>
    </div>
  </div>

  <!-- Special buttons -->
  <div class="special-btns">
    <button class="btn btn-outline btn-sm" onclick="sendToolsList()">tools/list (all servers)</button>
    <button class="btn btn-red btn-sm" onclick="sendMalformed()">Malformed Request</button>
    <button class="btn btn-sm" onclick="bulkTest()">Bulk Test (10 requests)</button>
    <span class="ts" id="bulkStatus"></span>
  </div>
  <div class="result" id="res-special" style="margin-top:12px"></div>
</div>

<!-- ════════════════════════════════════════════════ -->
<!-- TAB 3: PROMETHEUS                               -->
<!-- ════════════════════════════════════════════════ -->
<div class="tab-content" id="tab-prometheus">

  <div class="prom-section">
    <h3>Enable User Workload Monitoring on OCP</h3>
    <p style="color:var(--text-dim);margin-bottom:14px">OpenShift ships with a built-in Prometheus stack. To scrape metrics from your own workloads (like Praxis), you need to enable user workload monitoring.</p>
    <ol>
      <li><span class="step-num">1</span> Create or edit the <code style="font-family:var(--mono);color:var(--accent)">cluster-monitoring-config</code> ConfigMap:</li>
    </ol>
    <div class="code-block">oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml 2>/dev/null || \
oc -n openshift-monitoring create configmap cluster-monitoring-config

oc -n openshift-monitoring patch configmap cluster-monitoring-config \
  --type merge -p '{
    "data": {
      "config.yaml": "enableUserWorkload: true"
    }
  }'</div>
    <ol start="2">
      <li><span class="step-num">2</span> Wait for the <code style="font-family:var(--mono);color:var(--accent)">prometheus-user-workload</code> pods to start:</li>
    </ol>
    <div class="code-block">oc -n openshift-user-workload-monitoring get pods -w
# Wait until prometheus-user-workload-0 and prometheus-user-workload-1 are Running</div>
    <ol start="3">
      <li><span class="step-num">3</span> Apply the ServiceMonitor (included in the deploy script):</li>
    </ol>
    <div class="code-block">apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: praxis-ai-metrics
  labels:
    app: praxis-ai
spec:
  selector:
    matchLabels:
      app: praxis-ai
  endpoints:
    - port: metrics        # port 9902
      interval: 15s
      path: /metrics</div>
    <ol start="4">
      <li><span class="step-num">4</span> Verify in the OCP console: <strong>Observe → Metrics</strong> → query <code style="font-family:var(--mono);color:var(--accent)">praxis_mcp_requests_total</code></li>
    </ol>
  </div>

  <div class="prom-section">
    <h3>PromQL Queries — by Plane</h3>
    <p style="color:var(--text-dim);margin-bottom:14px">Copy these into OCP Console → Observe → Metrics or Grafana. Grouped by control plane vs data plane.</p>

    <div style="font-size:12px;font-weight:700;color:#00bcd4;text-transform:uppercase;letter-spacing:.5px;margin:16px 0 10px;display:flex;align-items:center;gap:8px"><span class="dot-ctrl"></span>CONTROL PLANE QUERIES</div>

    <div class="query-card">
      <div class="q">
        <div class="q-label">Control plane request rate (discovery + negotiation)</div>
        <div class="q-code">sum(rate(praxis_mcp_requests_total{method=~"initialize|server/discover|tools/list|ping"}[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Control plane breakdown by method</div>
        <div class="q-code">sum by (method) (rate(praxis_mcp_requests_total{method=~"initialize|server/discover|tools/list|ping"}[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>

    <div style="font-size:12px;font-weight:700;color:#ff9800;text-transform:uppercase;letter-spacing:.5px;margin:20px 0 10px;display:flex;align-items:center;gap:8px"><span class="dot-data"></span>DATA PLANE QUERIES</div>

    <div class="query-card">
      <div class="q">
        <div class="q-label">Data plane request rate (tool execution)</div>
        <div class="q-code">sum(rate(praxis_mcp_requests_total{method="tools/call"}[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Tool call rate by tool name</div>
        <div class="q-code">sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Tool call rate by cluster (which backend is hot?)</div>
        <div class="q-code">sum by (cluster) (rate(praxis_mcp_tool_calls_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">P99 tool call latency (data plane only)</div>
        <div class="q-code">praxis_mcp_tool_call_duration_seconds{quantile="0.99"}</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Latency by tool name (p50)</div>
        <div class="q-code">praxis_mcp_tool_call_duration_seconds{quantile="0.5"}</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Error rate by cluster</div>
        <div class="q-code">sum by (cluster) (rate(praxis_mcp_tool_calls_total{status="error"}[5m])) / sum by (cluster) (rate(praxis_mcp_tool_calls_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>

    <div style="font-size:12px;font-weight:700;color:var(--red);text-transform:uppercase;letter-spacing:.5px;margin:20px 0 10px;display:flex;align-items:center;gap:8px"><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--red)"></span>REJECTION QUERIES (BOTH PLANES)</div>

    <div class="query-card">
      <div class="q">
        <div class="q-label">Rejection ratio (rejections / total requests)</div>
        <div class="q-code">sum(rate(praxis_mcp_filter_rejections_total[5m])) / sum(rate(praxis_mcp_requests_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Rejections by reason</div>
        <div class="q-code">sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>

    <div style="font-size:12px;font-weight:700;color:var(--text-dim);text-transform:uppercase;letter-spacing:.5px;margin:20px 0 10px">OVERALL</div>

    <div class="query-card">
      <div class="q">
        <div class="q-label">Control vs data plane ratio</div>
        <div class="q-code">sum(rate(praxis_mcp_requests_total{method="tools/call"}[5m])) / sum(rate(praxis_mcp_requests_total[5m]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
    <div class="query-card">
      <div class="q">
        <div class="q-label">Hourly request breakdown by method</div>
        <div class="q-code">sum by (method) (increase(praxis_mcp_requests_total[1h]))</div>
      </div>
      <button class="copy-btn" onclick="copyQ(this)">Copy</button>
    </div>
  </div>

  <div class="prom-section">
    <h3>Grafana Dashboard (importable JSON)</h3>
    <p style="color:var(--text-dim);margin-bottom:10px">Copy this JSON and import via Grafana → Dashboards → Import.</p>
    <div class="code-block" id="grafanaJson">{
  "dashboard": {
    "title": "Praxis MCP Metrics",
    "panels": [
      {
        "title": "MCP Request Rate",
        "type": "timeseries",
        "targets": [{"expr": "sum by (method) (rate(praxis_mcp_requests_total[5m]))"}],
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
      },
      {
        "title": "Tool Call Rate by Tool",
        "type": "timeseries",
        "targets": [{"expr": "sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))"}],
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
      },
      {
        "title": "Tool Call Latency (p50/p99)",
        "type": "timeseries",
        "targets": [
          {"expr": "histogram_quantile(0.5, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))", "legendFormat": "p50"},
          {"expr": "histogram_quantile(0.99, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))", "legendFormat": "p99"}
        ],
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8}
      },
      {
        "title": "Filter Rejections",
        "type": "timeseries",
        "targets": [{"expr": "sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))"}],
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8}
      }
    ],
    "time": {"from": "now-1h", "to": "now"},
    "refresh": "10s"
  }
}</div>
    <button class="btn btn-outline btn-sm" onclick="copyBlock('grafanaJson')">Copy JSON</button>
  </div>

  <div class="prom-section">
    <h3>Alert Examples (PrometheusRule)</h3>
    <div class="code-block">apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: praxis-mcp-alerts
spec:
  groups:
    - name: mcp.rules
      rules:
        - alert: McpHighRejectionRate
          expr: |
            rate(praxis_mcp_filter_rejections_total[5m])
            / rate(praxis_mcp_requests_total[5m]) > 0.1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "MCP rejection rate above 10%"

        - alert: McpToolCallErrorRate
          expr: |
            sum by (tool) (rate(praxis_mcp_tool_calls_total{status="error"}[5m]))
            / sum by (tool) (rate(praxis_mcp_tool_calls_total[5m])) > 0.25
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "MCP tool error rate above 25%"

        - alert: McpNoTraffic
          expr: absent(rate(praxis_mcp_requests_total[15m]) > 0)
          for: 15m
          labels:
            severity: info
          annotations:
            summary: "No MCP traffic for 15 minutes"</div>
  </div>
</div>

<!-- ════════════════════════════════════════════════ -->
<!-- TAB 4: ARCHITECTURE (3D)                        -->
<!-- ════════════════════════════════════════════════ -->
<div class="tab-content" id="tab-architecture" style="padding:0;position:relative">
  <div class="arch-toolbar">
    <button class="btn btn-sm" onclick="archSimulate()">Simulate Traffic</button>
    <button class="btn btn-sm btn-outline" style="background:rgba(0,188,212,.15);border-color:#00bcd4;color:#00bcd4" onclick="archSimulateCtrl()">Control Plane</button>
    <button class="btn btn-sm btn-outline" style="background:rgba(255,152,0,.15);border-color:#ff9800;color:#ff9800" onclick="archSimulateData()">Data Plane</button>
    <button class="btn btn-sm btn-outline" onclick="archReset()">Reset View</button>
  </div>
  <div class="arch-tooltip" id="archTooltip"><h4></h4><p></p></div>
  <div class="arch-legend">
    <h4>Traffic Paths</h4>
    <div class="legend-row"><div class="legend-dot" style="background:#00bcd4"></div> Control plane (tools/list, initialize, discover)</div>
    <div class="legend-row"><div class="legend-dot" style="background:#34d399"></div> Data plane → Weather MCP</div>
    <div class="legend-row"><div class="legend-dot" style="background:#fbbf24"></div> Data plane → Calculator MCP</div>
    <div class="legend-row"><div class="legend-dot" style="background:#a78bfa"></div> Data plane → Translator MCP</div>
    <div class="legend-row"><div class="legend-dot" style="background:#f87171"></div> Rejected (stops at MCP Filter)</div>
    <div class="legend-row"><div class="legend-line" style="background:#e85d3a"></div> Prometheus scrape (port 9902)</div>
    <div style="margin-top:8px;font-size:10px;color:var(--text-dim)">
      <strong style="color:#00bcd4">Control plane</strong>: may stop at Praxis<br>
      <strong style="color:#ff9800">Data plane</strong>: flows to upstream MCP server
    </div>
  </div>
  <canvas id="three-canvas"></canvas>
</div>

<!-- ════════════════════════════════════════════════ -->
<!-- SCRIPTS                                         -->
<!-- ════════════════════════════════════════════════ -->
<script>
/* ── Tab switching ── */
function switchTab(id) {
  document.querySelectorAll('.tab-btn').forEach((b,i) => {
    const tabs = ['metrics','testlab','prometheus','architecture'];
    b.classList.toggle('active', tabs[i] === id);
  });
  document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
  document.getElementById('tab-' + id).classList.add('active');
  if (id === 'architecture') initArch();
}

/* ── Helpers ── */
function v(id) { return document.getElementById(id).value; }
function fmtMs(s) { return s < .001 ? (s*1e6).toFixed(0)+'µs' : s < 1 ? (s*1e3).toFixed(1)+'ms' : s.toFixed(2)+'s'; }

/* ── Metrics parsing ── */
function parseMetrics(raw) {
  const d = { req:{}, tools:{}, rej:{}, lat:{}, latSum:{}, latCount:{} };
  for (const line of raw.split('\n')) {
    if (!line.startsWith('praxis_mcp_') || line.startsWith('#')) continue;
    const m = line.match(/^(\S+?)(\{([^}]*)\})?\s+(\S+)$/);
    if (!m) continue;
    const [, name,, lblStr, val] = m;
    const n = parseFloat(val);
    const lb = {};
    if (lblStr) lblStr.split(',').forEach(p => { const [k,vv] = p.split('='); lb[k] = vv.replace(/"/g,''); });

    if (name === 'praxis_mcp_requests_total') d.req[lb.method||'?'] = (d.req[lb.method||'?']||0) + n;
    else if (name === 'praxis_mcp_tool_calls_total') { const k = lb.tool+'/'+lb.status; d.tools[k] = (d.tools[k]||0)+n; }
    else if (name === 'praxis_mcp_filter_rejections_total') d.rej[lb.reason||'?'] = (d.rej[lb.reason||'?']||0)+n;
    else if (name === 'praxis_mcp_tool_call_duration_seconds' && lb.quantile) d.lat['p'+Math.round(parseFloat(lb.quantile)*100)] = n;
    else if (name === 'praxis_mcp_tool_call_duration_seconds_sum') d.latSum[lb.tool||'all'] = n;
    else if (name === 'praxis_mcp_tool_call_duration_seconds_count') d.latCount[lb.tool||'all'] = n;
  }
  return d;
}

function renderBars(el, items, color) {
  const c = document.getElementById(el);
  if (!items.length) { c.innerHTML = '<div style="color:var(--text-dim);font-size:12px">No data yet</div>'; return; }
  const mx = Math.max(...items.map(i => i.v), 1);
  c.innerHTML = items.map(i => `<div class="bar-row"><div class="bar-label">${i.l}</div><div class="bar-track"><div class="bar-fill" style="width:${(i.v/mx)*100}%;background:${color}"></div></div><div class="bar-val">${i.d}</div></div>`).join('');
}

function tags(el, items, cls) {
  document.getElementById(el).innerHTML = items.map(([k,vv]) => `<span class="tag ${cls}">${k}: ${vv}</span>`).join('');
}

async function refreshMetrics() {
  const dot = document.getElementById('statusDot');
  try {
    const r = await fetch('/api/metrics');
    const raw = await r.text();
    dot.className = 'dot ok';
    const d = parseMetrics(raw);

    // Cards
    const totalReq = Object.values(d.req).reduce((a,b)=>a+b,0);
    document.getElementById('m-total-req').textContent = totalReq||'0';
    tags('m-req-tags', Object.entries(d.req), 'tag-b');

    const toolEntries = Object.entries(d.tools);
    const totalTools = toolEntries.reduce((a,[,vv])=>a+vv,0);
    const okT = toolEntries.filter(([k])=>k.endsWith('/ok')).reduce((a,[,vv])=>a+vv,0);
    const errT = toolEntries.filter(([k])=>k.endsWith('/error')).reduce((a,[,vv])=>a+vv,0);
    document.getElementById('m-total-tools').textContent = totalTools||'0';
    const tt = []; if(okT) tt.push(['ok',okT]); if(errT) tt.push(['err',errT]);
    tags('m-tool-tags', okT?[['ok',okT]]:[], 'tag-g');
    if(errT) document.getElementById('m-tool-tags').innerHTML += `<span class="tag tag-r">err: ${errT}</span>`;

    const tCount = Object.values(d.latCount).reduce((a,b)=>a+b,0);
    const tSum = Object.values(d.latSum).reduce((a,b)=>a+b,0);
    const avg = tCount > 0 ? tSum/tCount : 0;
    document.getElementById('m-avg-lat').textContent = tCount > 0 ? fmtMs(avg) : '—';
    const p99 = d.lat.p99||d.lat.p95||0;
    tags('m-lat-tags', p99?[['p99',fmtMs(p99)]]:[], 'tag-a');

    const totalRej = Object.values(d.rej).reduce((a,b)=>a+b,0);
    document.getElementById('m-total-rej').textContent = totalRej||'0';
    tags('m-rej-tags', Object.entries(d.rej), 'tag-r');

    // Control/data plane split
    const CTRL_METHODS = ['initialize','server/discover','tools/list','notifications/initialized','ping','resources/list','prompts/list'];
    const ctrlCount = Object.entries(d.req).filter(([k])=>CTRL_METHODS.includes(k)).reduce((a,[,vv])=>a+vv,0);
    const dataCount = Object.entries(d.req).filter(([k])=>!CTRL_METHODS.includes(k)).reduce((a,[,vv])=>a+vv,0);
    document.getElementById('m-ctrl-count').textContent = ctrlCount||'0';
    document.getElementById('m-data-count').textContent = dataCount||'0';
    const ctrlItems = Object.entries(d.req).filter(([k])=>CTRL_METHODS.includes(k)).map(([k,vv])=>({l:k,v:vv,d:String(vv)}));
    const dataItems = Object.entries(d.req).filter(([k])=>!CTRL_METHODS.includes(k)).map(([k,vv])=>({l:k,v:vv,d:String(vv)}));
    renderBars('chart-ctrl', ctrlItems, '#00bcd4');
    renderBars('chart-data', dataItems, '#ff9800');

    // Charts
    renderBars('chart-req', Object.entries(d.req).map(([k,vv])=>({l:k,v:vv,d:String(vv)})), 'var(--accent)');
    const toolMap = {};
    toolEntries.forEach(([k,vv]) => { const t = k.split('/')[0]; toolMap[t] = (toolMap[t]||0)+vv; });
    renderBars('chart-tool', Object.entries(toolMap).map(([k,vv])=>({l:k,v:vv,d:String(vv)})), 'var(--green)');
    const latItems = Object.entries(d.lat).filter(([k])=>['p0','p50','p90','p95','p99','p100'].includes(k)).map(([k,vv])=>({l:k,v:vv*1000,d:fmtMs(vv)}));
    renderBars('chart-lat', latItems, 'var(--amber)');

    // Raw
    const mcpLines = raw.split('\n').filter(l => l.includes('praxis_mcp_'));
    document.getElementById('rawMetrics').innerHTML = mcpLines.length
      ? mcpLines.map(l => { if(l.startsWith('#')) return l; const p=l.split(/\s+/); return `<span class="hl">${p[0]}</span> <span class="hv">${p.slice(1).join(' ')}</span>`; }).join('\n')
      : 'No praxis_mcp_* metrics yet. Send some test traffic first.';

    document.getElementById('lastUpdate').textContent = 'Updated ' + new Date().toLocaleTimeString();
  } catch(e) {
    dot.className = 'dot err';
    document.getElementById('rawMetrics').textContent = 'Cannot reach /api/metrics. Is Praxis running?\n\n' + e.message;
  }
}

/* ── Test Lab ── */
let reqId = 1;
async function sendTool(server, tool, args, btnEl) {
  const resEl = btnEl.parentElement.querySelector('.result');
  resEl.classList.add('show');
  resEl.textContent = 'Sending…';
  resEl.style.color = 'var(--text-dim)';
  try {
    const resp = await fetch('/api/mcp', {
      method:'POST',
      headers: {
        'Content-Type':'application/json',
        'Mcp-Protocol-Version':'2025-11-25',
        'Mcp-Method':'tools/call',
        'Mcp-Target-Server': server
      },
      body: JSON.stringify({jsonrpc:'2.0', id:reqId++, method:'tools/call', params:{name:tool, arguments:args}})
    });
    const text = await resp.text();
    let display = `HTTP ${resp.status}\n`;
    try { display += JSON.stringify(JSON.parse(text),null,2).substring(0,300); } catch { display += text.substring(0,300); }
    resEl.textContent = display;
    resEl.style.color = resp.status < 400 ? 'var(--green)' : 'var(--amber)';
  } catch(e) { resEl.textContent = 'Error: '+e.message; resEl.style.color = 'var(--red)'; }
}

async function sendToolsList() {
  const el = document.getElementById('res-special');
  el.classList.add('show');
  el.textContent = 'Sending tools/list…';
  el.style.color = 'var(--text-dim)';
  try {
    const r = await fetch('/api/mcp', {
      method:'POST',
      headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'tools/list'},
      body: JSON.stringify({jsonrpc:'2.0',id:reqId++,method:'tools/list',params:{}})
    });
    const t = await r.text();
    el.textContent = `HTTP ${r.status}\n` + (JSON.stringify(JSON.parse(t),null,2).substring(0,500) || t.substring(0,500));
    el.style.color = r.status < 400 ? 'var(--green)' : 'var(--amber)';
  } catch(e) { el.textContent = 'Error: '+e.message; el.style.color='var(--red)'; }
}

async function sendMalformed() {
  const el = document.getElementById('res-special');
  el.classList.add('show');
  el.textContent = 'Sending malformed request (no Mcp-Method header)…';
  el.style.color = 'var(--text-dim)';
  try {
    const r = await fetch('/api/mcp', {
      method:'POST',
      headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25'},
      body: JSON.stringify({jsonrpc:'2.0',id:reqId++,method:'tools/call',params:{}})
    });
    const t = await r.text();
    el.textContent = `HTTP ${r.status}\n` + t.substring(0,300);
    el.style.color = 'var(--amber)';
  } catch(e) { el.textContent = 'Error: '+e.message; el.style.color='var(--red)'; }
}

async function bulkTest() {
  const st = document.getElementById('bulkStatus');
  st.textContent = 'Sending 10 requests…';
  const calls = [
    {s:'weather',t:'get_weather',a:{city:'NYC'}},
    {s:'weather',t:'forecast',a:{city:'London',days:3}},
    {s:'calculator',t:'add',a:{a:10,b:20}},
    {s:'calculator',t:'multiply',a:{a:7,b:8}},
    {s:'calculator',t:'factorial',a:{n:12}},
    {s:'translator',t:'translate',a:{text:'Hello',from_lang:'en',to_lang:'fr'}},
    {s:'translator',t:'detect_language',a:{text:'Hola mundo'}},
    {s:'weather',t:'get_weather',a:{city:'Berlin'}},
    {s:'calculator',t:'add',a:{a:100,b:200}},
    {s:'translator',t:'translate',a:{text:'Good morning',from_lang:'en',to_lang:'de'}},
  ];
  let ok=0, fail=0;
  await Promise.all(calls.map(async c => {
    try {
      const r = await fetch('/api/mcp', {
        method:'POST',
        headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'tools/call','Mcp-Target-Server':c.s},
        body:JSON.stringify({jsonrpc:'2.0',id:reqId++,method:'tools/call',params:{name:c.t,arguments:c.a}})
      });
      r.status < 500 ? ok++ : fail++;
    } catch { fail++; }
  }));
  st.textContent = `Done: ${ok} ok, ${fail} failed`;
  st.style.color = fail ? 'var(--amber)' : 'var(--green)';
  setTimeout(refreshMetrics, 500);
}

/* ── Prometheus tab ── */
function copyQ(btn) {
  const code = btn.parentElement.querySelector('.q-code').textContent;
  navigator.clipboard.writeText(code).then(() => { btn.textContent = 'Copied!'; setTimeout(()=>btn.textContent='Copy', 1500); });
}
function copyBlock(id) {
  navigator.clipboard.writeText(document.getElementById(id).textContent);
}

/* ── Auto-refresh ── */
refreshMetrics();
setInterval(refreshMetrics, 8000);

/* ═══════════════════════════════════════════════════ */
/* 3D ARCHITECTURE DIAGRAM                            */
/* ═══════════════════════════════════════════════════ */
let archInited = false;
let scene, camera, renderer, labels3d = [], particles = [];
let isDragging = false, prevMouse = {x:0,y:0}, spherical = {theta:0.3, phi:1.2, radius:28};
let hoveredObj = null;
const raycaster = new THREE.Raycaster();
const mouse2 = new THREE.Vector2();
const componentInfo = {};

function initArch() {
  if (archInited) { onWindowResize(); return; }
  archInited = true;

  const canvas = document.getElementById('three-canvas');
  const container = document.getElementById('tab-architecture');

  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0f1117);

  camera = new THREE.PerspectiveCamera(50, container.clientWidth / container.clientHeight, 0.1, 100);
  updateCamera();

  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setSize(container.clientWidth, container.clientHeight);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

  // Lights
  scene.add(new THREE.AmbientLight(0xffffff, 0.4));
  const dl = new THREE.DirectionalLight(0xffffff, 0.8);
  dl.position.set(5, 10, 7);
  scene.add(dl);

  // Grid
  const grid = new THREE.GridHelper(40, 40, 0x1e222d, 0x1e222d);
  grid.position.y = -3;
  scene.add(grid);

  buildScene();

  // Mouse events
  canvas.addEventListener('mousedown', e => { isDragging = true; prevMouse = {x:e.clientX, y:e.clientY}; });
  canvas.addEventListener('mousemove', e => {
    if (isDragging) {
      const dx = e.clientX - prevMouse.x;
      const dy = e.clientY - prevMouse.y;
      spherical.theta -= dx * 0.005;
      spherical.phi = Math.max(0.2, Math.min(Math.PI - 0.2, spherical.phi - dy * 0.005));
      prevMouse = {x:e.clientX, y:e.clientY};
      updateCamera();
    }
    // Hover
    const rect = canvas.getBoundingClientRect();
    mouse2.x = ((e.clientX - rect.left) / rect.width) * 2 - 1;
    mouse2.y = -((e.clientY - rect.top) / rect.height) * 2 + 1;
    raycaster.setFromCamera(mouse2, camera);
    const hits = raycaster.intersectObjects(scene.children, true);
    const tip = document.getElementById('archTooltip');
    let found = null;
    for (const h of hits) {
      const obj = h.object;
      if (obj.userData && obj.userData.info) { found = obj; break; }
    }
    if (found && found.userData.info) {
      tip.style.display = 'block';
      tip.style.left = (e.clientX - canvas.getBoundingClientRect().left + 12) + 'px';
      tip.style.top = (e.clientY - canvas.getBoundingClientRect().top + 12) + 'px';
      tip.querySelector('h4').textContent = found.userData.info.title;
      tip.querySelector('p').textContent = found.userData.info.desc;
    } else {
      tip.style.display = 'none';
    }
  });
  canvas.addEventListener('mouseup', () => isDragging = false);
  canvas.addEventListener('mouseleave', () => { isDragging = false; document.getElementById('archTooltip').style.display='none'; });
  canvas.addEventListener('wheel', e => {
    spherical.radius = Math.max(8, Math.min(40, spherical.radius + e.deltaY * 0.02));
    updateCamera();
    e.preventDefault();
  }, {passive:false});

  window.addEventListener('resize', onWindowResize);

  // Spawn initial particles
  for (let i = 0; i < 3; i++) spawnParticle(i);

  animate();
}

function updateCamera() {
  const r = spherical.radius;
  camera.position.set(
    r * Math.sin(spherical.phi) * Math.sin(spherical.theta),
    r * Math.cos(spherical.phi),
    r * Math.sin(spherical.phi) * Math.cos(spherical.theta)
  );
  camera.lookAt(0, 0, 0);
}

function onWindowResize() {
  const c = document.getElementById('tab-architecture');
  if (!c || !renderer) return;
  camera.aspect = c.clientWidth / c.clientHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(c.clientWidth, c.clientHeight);
}

function createBox(w, h, d, color, opacity, pos, info) {
  const geo = new THREE.BoxGeometry(w, h, d);
  const mat = new THREE.MeshPhongMaterial({ color, transparent: opacity < 1, opacity, flatShading: true });
  const mesh = new THREE.Mesh(geo, mat);
  mesh.position.set(pos.x, pos.y, pos.z);
  if (info) mesh.userData.info = info;
  scene.add(mesh);
  return mesh;
}

function createLabel(text, subtext, pos) {
  const div = document.createElement('div');
  div.className = 'three-label';
  div.innerHTML = text + (subtext ? `<span class="three-sublabel">${subtext}</span>` : '');
  document.getElementById('tab-architecture').appendChild(div);
  labels3d.push({ el: div, pos: new THREE.Vector3(pos.x, pos.y, pos.z) });
  return div;
}

function createLine(from, to, color) {
  const pts = [new THREE.Vector3(from.x,from.y,from.z), new THREE.Vector3(to.x,to.y,to.z)];
  const geo = new THREE.BufferGeometry().setFromPoints(pts);
  const mat = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.3 });
  const line = new THREE.Line(geo, mat);
  scene.add(line);
  return line;
}

function createDashedLine(from, to, color) {
  const pts = [new THREE.Vector3(from.x,from.y,from.z), new THREE.Vector3(to.x,to.y,to.z)];
  const geo = new THREE.BufferGeometry().setFromPoints(pts);
  const mat = new THREE.LineDashedMaterial({ color, dashSize: 0.3, gapSize: 0.2, transparent: true, opacity: 0.4 });
  const line = new THREE.Line(geo, mat);
  line.computeLineDistances();
  scene.add(line);
}

const PATHS = [];  // [{points:[], color}]

function buildScene() {
  // Agent (far left)
  createBox(2, 2, 1.5, 0x6c8cff, 0.9, {x:-11, y:0, z:0},
    {title:'AI Agent', desc:'The client application (or agentic framework) making MCP tool calls. Sends JSON-RPC requests with Mcp-Protocol-Version and Mcp-Method headers.'});
  createLabel('AI Agent', 'MCP Client', {x:-11, y:1.6, z:0});

  // OCP Route / HAProxy (between agent and Praxis)
  createBox(1.8, 1.4, 1.5, 0xee0000, 0.8, {x:-6, y:0, z:0},
    {title:'OCP Route (HAProxy)', desc:'OpenShift built-in ingress controller. TLS termination, routing by hostname. No custom proxy needed — this is standard OCP infrastructure. Red Hat maintains the HAProxy-based router.'});
  createLabel('OCP Route', 'HAProxy ingress', {x:-6, y:1.3, z:0});

  // Praxis outer shell (center)
  createBox(6, 4, 3, 0x6c8cff, 0.08, {x:1, y:0, z:0},
    {title:'Praxis AI Gateway', desc:'Rust-native HTTP proxy (CNCF Sandbox, Red Hat-maintained). Processes requests through a filter pipeline before forwarding to upstream MCP servers. This is where MCP metrics are recorded.'});
  createLabel('Praxis AI Gateway', 'Red Hat / CNCF', {x:1, y:2.8, z:0});

  // Praxis internals
  createBox(1.6, 1, 2, 0x6c8cff, 0.6, {x:-0.5, y:0.8, z:0},
    {title:'MCP Filter', desc:'Parses JSON-RPC body, extracts method/tool/protocol version. Records praxis_mcp_requests_total and praxis_mcp_filter_rejections_total. Stores timing metadata for response-phase duration tracking.'});
  createLabel('MCP Filter', 'metrics', {x:-0.5, y:1.8, z:0});

  createBox(1.6, 1, 2, 0x4a6cdf, 0.6, {x:1.2, y:0.8, z:0},
    {title:'Router', desc:'Matches request path to upstream cluster based on configured routes. Selects the correct MCP server cluster for each tool call.'});
  createLabel('Router', 'routing', {x:1.2, y:1.8, z:0});

  createBox(1.6, 1, 2, 0x3a5cbf, 0.6, {x:2.9, y:0.8, z:0},
    {title:'Load Balancer', desc:'Selects a backend endpoint from the matched cluster. Supports round-robin and weighted algorithms.'});
  createLabel('LB', 'balancing', {x:2.9, y:1.8, z:0});

  // MCP Servers (right)
  const servers = [
    {y:3,  color:0x34d399, name:'Weather MCP',     tools:'get_weather, forecast',         info:'Simulates weather API. 50-150ms latency.'},
    {y:0,  color:0xfbbf24, name:'Calculator MCP',   tools:'add, multiply, factorial',      info:'Pure compute operations. 5-20ms latency.'},
    {y:-3, color:0xa78bfa, name:'Translator MCP',   tools:'translate, detect_language',     info:'Simulates translation API. 200-500ms latency.'},
  ];
  servers.forEach(s => {
    createBox(2.5, 1.5, 1.5, s.color, 0.75, {x:9, y:s.y, z:0},
      {title:s.name, desc:s.info + ' Tools: ' + s.tools});
    createLabel(s.name, s.tools, {x:9, y:s.y+1.3, z:0});
  });

  // Prometheus (bottom-left)
  createBox(2.5, 1.2, 1.5, 0xe85d3a, 0.75, {x:-1.5, y:-4, z:0},
    {title:'Prometheus', desc:'OCP built-in monitoring. Scrapes /metrics (port 9902) every 15s via ServiceMonitor CR. Stores praxis_mcp_* time series. Part of the OCP user workload monitoring stack.'});
  createLabel('Prometheus', 'ServiceMonitor', {x:-1.5, y:-3, z:0});

  // Grafana (bottom-right)
  createBox(2.5, 1.2, 1.5, 0xf46800, 0.75, {x:3.5, y:-4, z:0},
    {title:'Grafana', desc:'OCP built-in dashboards. Visualizes praxis_mcp_* metrics with pre-built panels for request rates, tool call latency, error ratios, and rejection breakdowns. Import the included dashboard JSON.'});
  createLabel('Grafana', 'OCP dashboards', {x:3.5, y:-3, z:0});

  // Lines: Agent → OCP Route
  createLine({x:-10,y:0,z:0}, {x:-6.9,y:0,z:0}, 0xee0000);

  // Lines: OCP Route → Praxis
  createLine({x:-5.1,y:0,z:0}, {x:-2,y:0,z:0}, 0x6c8cff);

  // Lines: Praxis → MCP Servers
  createLine({x:4,y:0,z:0}, {x:7.5,y:3,z:0},  0x34d399);
  createLine({x:4,y:0,z:0}, {x:7.5,y:0,z:0},  0xfbbf24);
  createLine({x:4,y:0,z:0}, {x:7.5,y:-3,z:0}, 0xa78bfa);

  // Dashed: Praxis → Prometheus (metrics scrape)
  createDashedLine({x:1,y:-2,z:0}, {x:-1.5,y:-3.4,z:0}, 0xe85d3a);

  // Dashed: Prometheus → Grafana
  createDashedLine({x:-0.2,y:-4,z:0}, {x:2.2,y:-4,z:0}, 0xf46800);

  // Metric recording point indicators (small glowing spheres)
  const recorderGeo = new THREE.SphereGeometry(0.15, 12, 12);
  // requests_total recorded at MCP Filter (both planes)
  const rec1 = new THREE.Mesh(recorderGeo, new THREE.MeshBasicMaterial({color:0x00ff88}));
  rec1.position.set(-0.5, 0.3, 1.2);
  rec1.userData.info = {title:'records: requests_total', desc:'Counter incremented here for EVERY MCP request (control + data plane). Labels: method, protocol_version.'};
  scene.add(rec1);
  createLabel('requests_total', null, {x:-0.5, y:-0.1, z:1.2});

  // tool_calls_total + duration recorded in on_response (data plane only)
  const rec2 = new THREE.Mesh(recorderGeo.clone(), new THREE.MeshBasicMaterial({color:0xff9800}));
  rec2.position.set(2.9, 0.3, 1.2);
  rec2.userData.info = {title:'records: tool_calls_total + duration', desc:'Recorded in on_response phase — only fires for tools/call (DATA PLANE). Measures round-trip time to upstream MCP server.'};
  scene.add(rec2);
  createLabel('tool_calls + duration', null, {x:2.9, y:-0.1, z:1.2});

  // Plane boundary labels (floating text)
  createLabel('─── CONTROL PLANE ───', 'tools/list, initialize, discover', {x:1, y:3.8, z:-1.5});
  createLabel('─── DATA PLANE ───', 'tools/call → full pipeline → upstream', {x:1, y:3.8, z:1.5});

  // DATA PLANE paths (Agent → OCP Route → Praxis full pipeline → MCP Servers)
  PATHS.push(
    { points: [{x:-11,y:0,z:0},{x:-6,y:0,z:0},{x:-2,y:0.8,z:0},{x:2.9,y:0.8,z:0},{x:7.5,y:3,z:0},{x:9,y:3,z:0}], color: 0x34d399, plane: 'data' },
    { points: [{x:-11,y:0,z:0},{x:-6,y:0,z:0},{x:-2,y:0.8,z:0},{x:2.9,y:0.8,z:0},{x:7.5,y:0,z:0},{x:9,y:0,z:0}], color: 0xfbbf24, plane: 'data' },
    { points: [{x:-11,y:0,z:0},{x:-6,y:0,z:0},{x:-2,y:0.8,z:0},{x:2.9,y:0.8,z:0},{x:7.5,y:-3,z:0},{x:9,y:-3,z:0}], color: 0xa78bfa, plane: 'data' },
  );
  // CONTROL PLANE path (stops at MCP Filter — response generated by Praxis itself)
  PATHS.push(
    { points: [{x:-11,y:0,z:0},{x:-6,y:0,z:0},{x:-2,y:0.8,z:0},{x:-0.5,y:0.8,z:0},{x:-0.5,y:0.3,z:0}], color: 0x00bcd4, plane: 'ctrl' }
  );
  // Rejection path (stops at MCP Filter)
  PATHS.push(
    { points: [{x:-11,y:0,z:0},{x:-6,y:0,z:0},{x:-2,y:0.8,z:0},{x:-0.5,y:0.8,z:0}], color: 0xf87171, plane: 'reject' }
  );
}

function spawnParticle(pathIdx, speed) {
  const path = PATHS[pathIdx % PATHS.length];
  const geo = new THREE.SphereGeometry(0.12, 8, 8);
  const mat = new THREE.MeshBasicMaterial({ color: path.color });
  const sphere = new THREE.Mesh(geo, mat);
  sphere.userData.path = path.points;
  sphere.userData.t = 0;
  sphere.userData.speed = speed || (0.003 + Math.random() * 0.004);
  sphere.userData.segLen = [];
  let totalLen = 0;
  for (let i = 0; i < path.points.length - 1; i++) {
    const a = path.points[i], b = path.points[i+1];
    const len = Math.sqrt((b.x-a.x)**2 + (b.y-a.y)**2 + (b.z-a.z)**2);
    sphere.userData.segLen.push(len);
    totalLen += len;
  }
  sphere.userData.totalLen = totalLen;
  scene.add(sphere);
  particles.push(sphere);
}

function animateParticles() {
  for (let i = particles.length - 1; i >= 0; i--) {
    const p = particles[i];
    p.userData.t += p.userData.speed;
    if (p.userData.t >= 1) {
      scene.remove(p);
      particles.splice(i, 1);
      // Respawn
      spawnParticle(Math.floor(Math.random() * PATHS.length));
      continue;
    }
    // Interpolate along path
    const dist = p.userData.t * p.userData.totalLen;
    let accum = 0;
    for (let s = 0; s < p.userData.segLen.length; s++) {
      if (accum + p.userData.segLen[s] >= dist) {
        const localT = (dist - accum) / p.userData.segLen[s];
        const a = p.userData.path[s], b = p.userData.path[s+1];
        p.position.set(
          a.x + (b.x - a.x) * localT,
          a.y + (b.y - a.y) * localT,
          a.z + (b.z - a.z) * localT
        );
        break;
      }
      accum += p.userData.segLen[s];
    }
    // Glow effect
    p.material.emissive = new THREE.Color(p.material.color.getHex());
    p.material.emissiveIntensity = 0.5;
  }
}

function updateLabels() {
  const container = document.getElementById('tab-architecture');
  const w = container.clientWidth, h = container.clientHeight;
  for (const lb of labels3d) {
    const v = lb.pos.clone().project(camera);
    const x = (v.x * 0.5 + 0.5) * w;
    const y = (-v.y * 0.5 + 0.5) * h;
    if (v.z > 1) { lb.el.style.display = 'none'; continue; }
    lb.el.style.display = '';
    lb.el.style.left = x + 'px';
    lb.el.style.top = y + 'px';
    lb.el.style.transform = 'translate(-50%, -100%)';
  }
}

function animate() {
  requestAnimationFrame(animate);
  animateParticles();
  renderer.render(scene, camera);
  updateLabels();
}

function archSimulate() {
  // Mix of data plane + control plane + rejection particles
  for (let i = 0; i < 15; i++) {
    setTimeout(() => spawnParticle(i % PATHS.length, 0.006 + Math.random()*0.006), i * 70);
  }
  bulkTest();
}

function archSimulateCtrl() {
  // Control plane only — tools/list, initialize (path index 3 = ctrl, 4 = reject)
  const ctrlIdx = PATHS.findIndex(p => p.plane === 'ctrl');
  for (let i = 0; i < 6; i++) {
    setTimeout(() => spawnParticle(ctrlIdx >= 0 ? ctrlIdx : 3, 0.005 + Math.random()*0.004), i * 120);
  }
  // Send real control plane traffic
  fetch('/api/mcp', {method:'POST', headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'tools/list'}, body:JSON.stringify({jsonrpc:'2.0',id:999,method:'tools/list',params:{}})}).catch(()=>{});
  fetch('/api/mcp', {method:'POST', headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'server/discover'}, body:JSON.stringify({jsonrpc:'2.0',id:998,method:'server/discover',params:{}})}).catch(()=>{});
  fetch('/api/mcp', {method:'POST', headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'initialize'}, body:JSON.stringify({jsonrpc:'2.0',id:997,method:'initialize',params:{}})}).catch(()=>{});
}

function archSimulateData() {
  // Data plane only — tools/call to all 3 servers
  const dataIdxs = PATHS.map((p,i) => p.plane === 'data' ? i : -1).filter(i => i >= 0);
  for (let i = 0; i < 9; i++) {
    setTimeout(() => spawnParticle(dataIdxs[i % dataIdxs.length], 0.005 + Math.random()*0.005), i * 90);
  }
  // Send real data plane traffic
  const calls = [
    {s:'weather',t:'get_weather',a:{city:'NYC'}},
    {s:'calculator',t:'add',a:{a:10,b:20}},
    {s:'translator',t:'translate',a:{text:'hello',from_lang:'en',to_lang:'es'}},
  ];
  calls.forEach(c => {
    fetch('/api/mcp', {method:'POST', headers:{'Content-Type':'application/json','Mcp-Protocol-Version':'2025-11-25','Mcp-Method':'tools/call','Mcp-Target-Server':c.s}, body:JSON.stringify({jsonrpc:'2.0',id:reqId++,method:'tools/call',params:{name:c.t,arguments:c.a}})}).catch(()=>{});
  });
}

function archReset() {
  spherical = {theta: 0.3, phi: 1.2, radius: 28};
  updateCamera();
}
</script>
</body>
</html>
EOF_DASHBOARD_HTML

echo "Embedded files extracted to $_DEPLOY_TMPDIR"

# ======== Deployment (from deploy-dashboard.sh) ========

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Praxis MCP Metrics — Full OCP-Native Deployment"
echo "══════════════════════════════════════════════════════════"
echo "  Project: $PROJECT"
echo ""
echo "  Architecture:"
echo "    Agent → OCP Route → Praxis → MCP Servers"
echo "                           ↓"
echo "                      Prometheus → Grafana"
echo ""

# ══════════════════════════════════════════
# Step 1: Project
# ══════════════════════════════════════════
echo -e "${CYAN}[1/8]${NC} Project setup"
if oc get project "$PROJECT" &>/dev/null; then
    oc project "$PROJECT" >/dev/null
    echo "  Using existing project '$PROJECT'"
else
    oc new-project "$PROJECT" --description="Praxis MCP metrics demo"
    echo "  Created project '$PROJECT'"
fi
echo ""

# ══════════════════════════════════════════
# Step 2: Deploy 3 mock MCP servers
# ══════════════════════════════════════════
echo -e "${CYAN}[2/8]${NC} Deploying 3 mock MCP servers (weather, calculator, translator)"
oc apply -f "$_DEPLOY_TMPDIR/multi-mcp-servers.yaml"

for svc in weather-mcp calculator-mcp translator-mcp; do
    echo -n "  Waiting for $svc... "
    if oc rollout status deployment/$svc --timeout=120s 2>/dev/null; then
        echo -e "${GREEN}ready${NC}"
    else
        echo -e "${YELLOW}still starting (will continue)${NC}"
    fi
done
echo ""

# ══════════════════════════════════════════
# Step 3: Praxis config + Deployment + Service + Route
# ══════════════════════════════════════════
echo -e "${CYAN}[3/8]${NC} Configuring Praxis AI Gateway (3 backend clusters)"

oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: praxis-ai-config
  labels:
    app: praxis-ai
data:
  config.yaml: |
    admin:
      address: "0.0.0.0:9901"
      metrics_address: "0.0.0.0:9902"

    insecure_options:
      allow_public_admin: true
      allow_private_endpoints: true
      allow_private_upstreams: true

    metrics:
      filter_duration: true

    listeners:
      - name: default
        address: "0.0.0.0:8080"
        filter_chains: [main]

    filter_chains:
      - name: main
        filters:
          - filter: mcp
            max_body_bytes: 65536

          - filter: router
            routes:
              - path_prefix: "/mcp/weather"
                cluster: weather-mcp
              - path_prefix: "/mcp/calc"
                cluster: calculator-mcp
              - path_prefix: "/mcp/translate"
                cluster: translator-mcp
              - path_prefix: "/mcp"
                cluster: weather-mcp

          - filter: load_balancer
            clusters:
              - name: weather-mcp
                endpoints:
                  - "weather-mcp:3001"
              - name: calculator-mcp
                endpoints:
                  - "calculator-mcp:3001"
              - name: translator-mcp
                endpoints:
                  - "translator-mcp:3001"
EOF
echo "  ConfigMap updated"

# Restart Praxis to pick up new config
echo "  Restarting Praxis..."
oc rollout restart deployment/praxis-ai 2>/dev/null || echo "  (praxis-ai deployment not found — will create below)"
sleep 2

# Ensure Praxis deployment + Service exist
if ! oc get deployment praxis-ai &>/dev/null; then
    INTERNAL_IMAGE=$(oc get imagestream praxis-ai -o jsonpath='{.status.dockerImageRepository}' 2>/dev/null):mcp-metrics
    echo "  Creating Praxis deployment with image: $INTERNAL_IMAGE"
    oc apply -f - <<EOF2
apiVersion: apps/v1
kind: Deployment
metadata:
  name: praxis-ai
  labels:
    app: praxis-ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: praxis-ai
  template:
    metadata:
      labels:
        app: praxis-ai
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9902"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: praxis-ai
          image: ${INTERNAL_IMAGE}
          args: ["-c", "/config/config.yaml"]
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 9901
              name: admin
            - containerPort: 9902
              name: metrics
          livenessProbe:
            httpGet:
              path: /healthy
              port: 9902
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthy
              port: 9902
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: praxis-ai-config
---
apiVersion: v1
kind: Service
metadata:
  name: praxis-ai
  labels:
    app: praxis-ai
spec:
  selector:
    app: praxis-ai
  ports:
    - port: 8080
      targetPort: 8080
      name: http
    - port: 9901
      targetPort: 9901
      name: admin
    - port: 9902
      targetPort: 9902
      name: metrics
EOF2
fi

# Create OCP Route for Praxis — this is the REAL client-facing endpoint.
# AI Agents / MCP clients connect here. No intermediary proxy.
echo "  Creating OCP Route for Praxis (client-facing endpoint)..."
oc apply -f - <<'PRAXIS_ROUTE'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: praxis-ai
  labels:
    app: praxis-ai
  annotations:
    haproxy.router.openshift.io/timeout: 60s
spec:
  to:
    kind: Service
    name: praxis-ai
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
PRAXIS_ROUTE

echo -n "  Waiting for Praxis... "
oc rollout status deployment/praxis-ai --timeout=120s 2>/dev/null && \
    echo -e "${GREEN}ready${NC}" || echo -e "${YELLOW}still starting${NC}"
echo ""

# ══════════════════════════════════════════
# Step 4: ServiceMonitor + PrometheusRule
# ══════════════════════════════════════════
echo -e "${CYAN}[4/8]${NC} Applying ServiceMonitor + PrometheusRule"
oc apply -f "$_DEPLOY_TMPDIR/servicemonitor.yaml" 2>/dev/null && \
    echo "  ServiceMonitor + PrometheusRule applied" || \
    echo -e "  ${YELLOW}Note: monitoring.coreos.com CRDs not available yet — apply after enabling user workload monitoring${NC}"
echo ""

# ══════════════════════════════════════════
# Step 5: Grafana dashboard ConfigMap
# ══════════════════════════════════════════
echo -e "${CYAN}[5/8]${NC} Creating Grafana dashboard ConfigMap"
if [[ -f "$_DEPLOY_TMPDIR/grafana-dashboard.json" ]]; then
    oc create configmap praxis-mcp-grafana \
        --from-file=praxis-mcp-metrics.json="$_DEPLOY_TMPDIR/grafana-dashboard.json" \
        --dry-run=client -o yaml | oc apply -f -
    oc label configmap praxis-mcp-grafana grafana_dashboard=true --overwrite 2>/dev/null
    echo "  Grafana dashboard ConfigMap created (label: grafana_dashboard=true)"
    echo "  Import via: OCP Console → Observe → Dashboards → Import → select 'praxis-mcp-grafana'"
else
    echo -e "  ${YELLOW}grafana-dashboard.json not found — skipping (Prometheus tab in demo dashboard has PromQL examples)${NC}"
fi
echo ""

# ══════════════════════════════════════════
# Step 6: Create httpd config (Red Hat web server as reverse proxy)
# ══════════════════════════════════════════
echo -e "${CYAN}[6/8]${NC} Creating Red Hat httpd reverse-proxy config"

oc apply -f - <<'HTTPD_CM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-httpd-conf
  labels:
    app: mcp-dashboard
data:
  httpd.conf: |
    # Red Hat httpd config for MCP metrics demo dashboard
    # This is a DEV/TEST tool — not part of the production data path.
    # In production, AI agents connect directly to the Praxis OCP Route.

    ServerRoot "/etc/httpd"
    Listen 8080

    LoadModule mpm_event_module modules/mod_mpm_event.so
    LoadModule unixd_module modules/mod_unixd.so
    LoadModule log_config_module modules/mod_log_config.so
    LoadModule mime_module modules/mod_mime.so
    LoadModule dir_module modules/mod_dir.so
    LoadModule authz_core_module modules/mod_authz_core.so
    LoadModule proxy_module modules/mod_proxy.so
    LoadModule proxy_http_module modules/mod_proxy_http.so
    LoadModule rewrite_module modules/mod_rewrite.so

    TypesConfig /etc/mime.types
    PidFile /tmp/httpd.pid
    ErrorLog /dev/stderr
    LogLevel warn
    LogFormat "%h %l %u %t \"%r\" %>s %b" common
    CustomLog /dev/stdout common

    DocumentRoot "/var/www/html"
    DirectoryIndex dashboard.html

    <Directory "/var/www/html">
        Require all granted
    </Directory>

    # ── Reverse proxy to Praxis AI Gateway ──
    # Routes the Mcp-Target-Server header to the correct backend path.
    # mod_proxy forwards all request headers (including MCP-*) by default.
    ProxyPreserveHost Off

    RewriteEngine On

    # Route by Mcp-Target-Server header → different Praxis path prefixes
    RewriteCond %{HTTP:Mcp-Target-Server} ^weather$
    RewriteRule ^/api/mcp$ http://praxis-ai:8080/mcp/weather [P,L]

    RewriteCond %{HTTP:Mcp-Target-Server} ^calculator$
    RewriteRule ^/api/mcp$ http://praxis-ai:8080/mcp/calc [P,L]

    RewriteCond %{HTTP:Mcp-Target-Server} ^translator$
    RewriteRule ^/api/mcp$ http://praxis-ai:8080/mcp/translate [P,L]

    # Default: no target header → weather cluster
    ProxyPass        /api/mcp http://praxis-ai:8080/mcp
    ProxyPassReverse /api/mcp http://praxis-ai:8080/mcp

    # Metrics endpoint
    ProxyPass        /api/metrics http://praxis-ai:9902/metrics
    ProxyPassReverse /api/metrics http://praxis-ai:9902/metrics
HTTPD_CM
echo "  httpd.conf ConfigMap created"
echo ""

# ══════════════════════════════════════════
# Step 7: Dashboard HTML ConfigMap
# ══════════════════════════════════════════
echo -e "${CYAN}[7/8]${NC} Creating dashboard HTML ConfigMap"
oc create configmap dashboard-html \
    --from-file=dashboard.html="$_DEPLOY_TMPDIR/dashboard.html" \
    --dry-run=client -o yaml | oc apply -f -
echo "  dashboard.html ConfigMap created"
echo ""

# ══════════════════════════════════════════
# Step 8: Deploy demo dashboard (Red Hat httpd) + Service + Route
# ══════════════════════════════════════════
echo -e "${CYAN}[8/8]${NC} Deploying demo dashboard (Red Hat httpd — ubi9/httpd-24)"

oc apply -f - <<'DASHBOARD'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-dashboard
  labels:
    app: mcp-dashboard
    purpose: demo-tooling
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-dashboard
  template:
    metadata:
      labels:
        app: mcp-dashboard
        purpose: demo-tooling
    spec:
      containers:
        - name: httpd
          image: registry.access.redhat.com/ubi9/httpd-24
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: httpd-conf
              mountPath: /etc/httpd/conf/httpd.conf
              subPath: httpd.conf
              readOnly: true
            - name: html
              mountPath: /var/www/html
              readOnly: true
      volumes:
        - name: httpd-conf
          configMap:
            name: dashboard-httpd-conf
        - name: html
          configMap:
            name: dashboard-html
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-dashboard
  labels:
    app: mcp-dashboard
spec:
  selector:
    app: mcp-dashboard
  ports:
    - port: 8080
      targetPort: 8080
      name: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mcp-dashboard
  labels:
    app: mcp-dashboard
    purpose: demo-tooling
spec:
  to:
    kind: Service
    name: mcp-dashboard
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
DASHBOARD

echo -n "  Waiting for dashboard... "
oc rollout status deployment/mcp-dashboard --timeout=120s 2>/dev/null && \
    echo -e "${GREEN}ready${NC}" || echo -e "${YELLOW}still starting${NC}"
echo ""

# ══════════════════════════════════════════
# Summary
# ══════════════════════════════════════════
PRAXIS_URL=$(oc get route praxis-ai -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
DASHBOARD_URL=$(oc get route mcp-dashboard -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo "══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}Deployment complete!${NC}"
echo ""
echo -e "  ${BOLD}Production endpoint (for AI agents / MCP clients):${NC}"
if [[ -n "$PRAXIS_URL" ]]; then
    echo -e "    ${CYAN}https://${PRAXIS_URL}/mcp${NC}"
else
    echo "    (Route not yet ready — check: oc get route praxis-ai)"
fi
echo ""
echo -e "  ${BOLD}Demo dashboard (dev/test tool):${NC}"
if [[ -n "$DASHBOARD_URL" ]]; then
    echo -e "    ${CYAN}https://${DASHBOARD_URL}${NC}"
else
    echo "    (Route not yet ready — check: oc get route mcp-dashboard)"
fi
echo ""
echo -e "  ${BOLD}Prometheus (OCP Console):${NC}"
echo "    Observe → Metrics → query: praxis_mcp_requests_total"
echo ""
echo -e "  ${BOLD}Grafana:${NC}"
echo "    Observe → Dashboards → Import from ConfigMap 'praxis-mcp-grafana'"
echo ""
echo "  Pods:"
oc get pods -l 'app in (praxis-ai, weather-mcp, calculator-mcp, translator-mcp, mcp-dashboard)' \
    --no-headers 2>/dev/null | while read line; do echo "    $line"; done
echo ""
echo "  Useful commands:"
echo "    oc logs -f -l app=praxis-ai             # Praxis gateway logs"
echo "    oc logs -f -l app=mcp-dashboard         # Dashboard httpd logs"
echo "    oc logs -f -l app=weather-mcp           # Weather server logs"
echo "    oc delete project $PROJECT              # Tear down everything"
echo ""
echo "══════════════════════════════════════════════════════════"
