# PR #1: feat(mcp): Prometheus metrics for MCP tool calls

## What this PR adds

**4 Prometheus metrics** for the MCP filter in [Praxis AI Gateway](https://github.com/praxis-proxy/ai) — giving full visibility into MCP tool call traffic that was previously invisible to monitoring.

Praxis already ships ~71 Prometheus metrics for HTTP, LLM inference, and intelligent routing. But the MCP filter — which parses JSON-RPC, validates headers, and routes tool calls to backends — has **zero metrics**. This PR closes that gap.

---

## Why this matters

Without MCP metrics, you're flying blind:

| Question | Before | After |
|----------|--------|-------|
| "Which tools are my agents calling?" | No idea — you see HTTP 200s but not tool names | `sum by (tool) (praxis_mcp_tool_calls_total)` |
| "Why is my agent slow?" | Could be LLM or tool backend — can't tell | `histogram_quantile(0.99, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))` |
| "Is someone sending garbage?" | Filter rejects silently — nobody knows | `sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))` |
| "What's my MCP request rate?" | Guess from HTTP access logs | `rate(praxis_mcp_requests_total[5m])` |

Competing gateways (Kong AI Gateway, Portkey) already ship tool-level metrics. This brings Praxis to parity.

---

## The 4 metrics

| Metric | Type | Labels | What it tells you |
|--------|------|--------|-------------------|
| `praxis_mcp_requests_total` | Counter | `method`, `protocol_version` | MCP requests by method (`tools/call`, `tools/list`, `initialize`, etc.) |
| `praxis_mcp_tool_calls_total` | Counter | `tool`, `cluster`, `status` | Per-tool call counts with success/failure — which tools are hot, which are failing |
| `praxis_mcp_tool_call_duration_seconds` | Histogram | `tool`, `cluster` | Upstream round-trip latency per tool — find slow backends before users notice |
| `praxis_mcp_filter_rejections_total` | Counter | `method`, `reason` | Requests rejected by the filter — misconfiguration, attacks, bad clients |

### Rejection reasons (closed set)

| Reason | When it fires |
|--------|--------------|
| `invalid_params` | `tools/call` sent without a tool name |
| `header_mismatch` | `Mcp-Name` header doesn't match the body |
| `missing_header` | Required MCP header is absent |
| `invalid_jsonrpc` | Body fails JSON-RPC parsing entirely |

---

## Architecture

![Praxis MCP Metrics Architecture](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/mcp-metrics/upstream-pr/architecture-metrics.png)

```
                                    ┌─────────────────────────────────────────┐
                                    │          OpenShift Cluster              │
                                    │                                        │
  ┌──────────┐    HTTPS    ┌────────┴──────────┐                             │
  │  Client  │────────────▶│   Praxis Proxy    │                             │
  │ (curl,   │             │                   │                             │
  │  agent)  │             │  MCP Filter:      │     ┌───────────────────┐   │
  └──────────┘             │  ┌─────────────┐  │────▶│  weather-mcp      │   │
                           │  │ Parse JSON  │  │     │  (mock, port 3001)│   │
                           │  │ RPC body    │  │     └───────────────────┘   │
                           │  ├─────────────┤  │                             │
                           │  │ Validate    │  │     ┌───────────────────┐   │
                           │  │ headers     │  │────▶│  calculator-mcp   │   │
                           │  ├─────────────┤  │     │  (mock, port 3002)│   │
                           │  │ Record      │  │     └───────────────────┘   │
                           │  │ metrics ◄───┼──┼─── NEW! 4 Prometheus       │
                           │  ├─────────────┤  │     counters               │
                           │  │ Route to    │  │     ┌───────────────────┐   │
                           │  │ backend     │  │────▶│  translator-mcp   │   │
                           │  └─────────────┘  │     │  (mock, port 3003)│   │
                           │                   │     └───────────────────┘   │
                           │  :9902/metrics ───┼──┐                          │
                           └───────────────────┘  │                          │
                                                  ▼                          │
                           ┌───────────────────┐  ┌───────────────────┐      │
                           │   ServiceMonitor  │─▶│   Prometheus      │      │
                           │   (scrapes :9902) │  │   (user-workload) │      │
                           └───────────────────┘  └───────────────────┘      │
                           ┌───────────────────┐                             │
                           │  Grafana Dashboard│  Visualizes metrics         │
                           └───────────────────┘                             │
                                    └────────────────────────────────────────┘
```

### Data flow

1. **Client** sends MCP JSON-RPC request (e.g. `tools/call` with tool `get_weather`)
2. **MCP filter** parses body, validates headers, increments `praxis_mcp_requests_total{method="tools/call"}`
3. **Praxis routes** request to the matched backend cluster
4. **On response**, filter records `praxis_mcp_tool_calls_total{tool="get_weather", cluster="weather-mcp", status="ok"}` and observes latency in the histogram
5. **If rejected** (bad params, missing headers): increments `praxis_mcp_filter_rejections_total{reason="invalid_params"}`
6. **Prometheus** scrapes `:9902/metrics` via ServiceMonitor
7. **Grafana / OCP Console** visualize the data

---

## How the image is built

The Praxis image is built **entirely on the OCP cluster** — no local Rust toolchain needed.

### Build chain

![OCP Build Pipeline](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/mcp-metrics/upstream-pr/build-chain.png)

```
┌─────────────────────────────────────────────────────────┐
│                    OCP Build Pipeline                     │
│                                                          │
│  1. Clone praxis-proxy/ai from GitHub (HEAD)             │
│     ┌──────────────────────────────────────┐             │
│     │  upstream source (unmodified)         │             │
│     │  filters/src/agentic/mcp/mod.rs      │             │
│     └──────────────────────────────────────┘             │
│                       │                                  │
│  2. Copy metrics.rs into the source tree                 │
│     ┌──────────────────────────────────────┐             │
│     │  + filters/src/agentic/mcp/metrics.rs │  ◀── NEW  │
│     └──────────────────────────────────────┘             │
│                       │                                  │
│  3. Run patch-mod-rs.py to wire metrics in               │
│     ┌──────────────────────────────────────┐             │
│     │  mod.rs patched:                      │             │
│     │  + mod metrics;                       │             │
│     │  + record_mcp_request() in on_request │             │
│     │  + record_tool_call_completed()       │             │
│     │    in on_response                     │             │
│     │  + record_filter_rejection()          │             │
│     │    in rejection paths                 │             │
│     └──────────────────────────────────────┘             │
│                       │                                  │
│  4. cargo build --release --features full                │
│     Builder:  rust:1.85-alpine3.21                       │
│     Runtime:  alpine:3.21 (UID 1001)                     │
│     Ports:    8080 (proxy), 9901 (admin), 9902 (metrics) │
│                       │                                  │
│  5. Push to internal registry                            │
│     image-registry.openshift-image-registry.svc:5000/    │
│       praxis-mcp-test/praxis-ai:mcp-metrics              │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### Build command

```bash
# One command builds everything on-cluster (~12-15 min)
bash build/build-on-ocp.sh
```

This creates a `BuildConfig` that:
- Uploads the patched source as build context
- Compiles Rust inside the builder container
- Produces a minimal Alpine runtime image
- Pushes to the internal registry

---

## OCP deployment

### What gets deployed

```bash
# One command deploys the full stack
bash deploy/deploy-all.sh
```

| Component | Purpose |
|-----------|---------|
| **Praxis AI Gateway** | Deployment with the patched image, OCP Route for HTTPS |
| **3 mock MCP servers** | weather-mcp (:3001), calculator-mcp (:3002), translator-mcp (:3003) |
| **Praxis config** | ConfigMap with 3 backend clusters, MCP filter enabled |
| **ServiceMonitor** | Prometheus scraping config for `:9902/metrics` |
| **Grafana dashboard** | Production dashboard JSON for MCP metrics |
| **Demo dashboard** | Interactive HTML dashboard (5 tabs) served via httpd |

### Cluster details

- **Cluster:** `ai154.dl154.dfw.ocp.run` (OCP 4.17)
- **Namespace:** `praxis-mcp-test`
- **Praxis endpoint:** `https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run`
- **Metrics endpoint:** `https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run:9902/metrics`

---

## Testing and verification

### Test traffic

```bash
PRAXIS_URL="https://$(oc get route praxis-ai -n praxis-mcp-test -o jsonpath='{.spec.host}')"

# 1. Successful tool call → increments requests_total + tool_calls_total + duration histogram
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: test-tenant-1" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Dallas"}}}'

# 2. Rejection (no tool name) → increments filter_rejections_total
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{}}'

# 3. Non-tool method → increments requests_total only
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
```

### Verify metrics are scraped

```bash
# Check raw metrics endpoint
curl -sk https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run:9902/metrics | grep praxis_mcp
```

### Metrics dashboard — live from OCP cluster

![Praxis MCP Metrics Dashboard](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/mcp-metrics/upstream-pr/metrics-dashboard.png)

| Metric | Live value |
|--------|-----------|
| `praxis_mcp_requests_total` | 247 |
| `praxis_mcp_tool_calls_total` | 183 |
| `praxis_mcp_tool_call_duration_seconds` (p50) | 42ms |
| `praxis_mcp_filter_rejections_total` | 31 |

Raw `/metrics` endpoint output:
```
# HELP praxis_mcp_requests_total Total MCP JSON-RPC requests
# TYPE praxis_mcp_requests_total counter
praxis_mcp_requests_total{method="tools/call",protocol_version="2024-11-05"} 183
praxis_mcp_requests_total{method="tools/list",protocol_version="2024-11-05"} 42
praxis_mcp_requests_total{method="initialize",protocol_version="2024-11-05"} 15
praxis_mcp_requests_total{method="ping",protocol_version="2024-11-05"} 7

# HELP praxis_mcp_tool_calls_total Completed tool call invocations
# TYPE praxis_mcp_tool_calls_total counter
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",status="ok"} 89
praxis_mcp_tool_calls_total{tool="calculate",cluster="calculator-mcp",status="ok"} 56
praxis_mcp_tool_calls_total{tool="translate",cluster="translator-mcp",status="ok"} 38

# HELP praxis_mcp_tool_call_duration_seconds Tool call round-trip latency
# TYPE praxis_mcp_tool_call_duration_seconds histogram
praxis_mcp_tool_call_duration_seconds_bucket{tool="get_weather",cluster="weather-mcp",le="0.05"} 45
praxis_mcp_tool_call_duration_seconds_bucket{tool="get_weather",cluster="weather-mcp",le="0.1"} 72
praxis_mcp_tool_call_duration_seconds_bucket{tool="get_weather",cluster="weather-mcp",le="0.5"} 89

# HELP praxis_mcp_filter_rejections_total Requests rejected by MCP filter
# TYPE praxis_mcp_filter_rejections_total counter
praxis_mcp_filter_rejections_total{method="tools/call",reason="invalid_params"} 18
praxis_mcp_filter_rejections_total{method="tools/call",reason="header_mismatch"} 8
praxis_mcp_filter_rejections_total{method="tools/call",reason="missing_header"} 5
```

### Verify in Prometheus (OCP Console → Observe → Metrics)

```promql
praxis_mcp_tool_calls_total
```

Prometheus query results from OCP Console → Observe → Metrics:

```
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",status="ok"} 89
praxis_mcp_tool_calls_total{tool="calculate",cluster="calculator-mcp",status="ok"} 56
praxis_mcp_tool_calls_total{tool="translate",cluster="translator-mcp",status="ok"} 38
```

Request rate query:
```promql
rate(praxis_mcp_requests_total[5m])
```

### Verify ServiceMonitor is working

```bash
# Check ServiceMonitor exists and targets are up
oc get servicemonitor -n praxis-mcp-test
oc get endpoints -n praxis-mcp-test praxis-ai-metrics
```

### Diagnostics script

```bash
# 8-layer end-to-end metrics pipeline checker
bash diagnostics/check-metrics.sh
```

---

## Implementation details

### Source file: `src/metrics.rs` (411 lines)

```rust
// 4 metrics with cardinality bounding
static MCP_REQUESTS: LazyLock<IntCounterVec> = ...
static MCP_TOOL_CALLS: LazyLock<IntCounterVec> = ...
static MCP_TOOL_DURATION: LazyLock<HistogramVec> = ...
static MCP_REJECTIONS: LazyLock<IntCounterVec> = ...

// 3 recording functions called from mod.rs
pub(crate) fn record_mcp_request(method: &str, protocol_version: Option<&str>) { ... }
pub(crate) fn record_tool_call_completed(tool: &str, cluster: &str, status: u16, duration: Duration) { ... }
pub(crate) fn record_filter_rejection(method: &str, reason: &str) { ... }
```

### Design decisions

- **Follows existing Praxis patterns** — same cardinality bounding approach as `llm_metrics.rs`, same label conventions, same test style
- **No new dependencies** — uses `prometheus` crate already in `Cargo.toml`
- **Tool name capped at 64 chars** — prevents cardinality explosion from malicious inputs
- **Status mapped to `ok`/`error`** — not raw HTTP codes, to keep cardinality bounded
- **Build-time patching** — `patch-mod-rs.py` wires metrics into `mod.rs` without forking Praxis

---

## Files in this PR

| File | Lines | Purpose |
|------|-------|---------|
| `src/metrics.rs` | 411 | The 4 Prometheus metrics with cardinality bounding |
| `src/patch-mod-rs.py` | ~80 | Build-time patcher wiring metrics into mod.rs |
| `build/Containerfile` | ~40 | Multi-stage Rust build for OCP |
| `build/build-on-ocp.sh` | ~60 | One-command OCP build script |
| `deploy/deploy-all.sh` | ~300 | Self-contained deployer (embeds all manifests) |
| `deploy/mock-servers.yaml` | ~100 | 3 mock MCP servers |
| `deploy/servicemonitor.yaml` | ~20 | Prometheus scraping config |
| `deploy/grafana-dashboard.json` | ~200 | Production Grafana dashboard |
| `dashboard/dashboard.html` | ~800 | Interactive 5-tab demo dashboard |
| `diagnostics/check-metrics.sh` | ~100 | 8-layer end-to-end checker |
| `test/mock-mcp-server.py` | ~50 | Standalone mock for local testing |
| `test/simulate-traffic.sh` | ~40 | Traffic generator |
| `upstream-pr/PR_DESCRIPTION.md` | ~150 | Ready-to-paste upstream PR description |
| `upstream-pr/GITHUB_ISSUE.md` | ~100 | Ready-to-file upstream GitHub issue |

---

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>
