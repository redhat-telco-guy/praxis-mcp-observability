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

---

## The 4 metrics

| Metric | Type | Labels | What it tells you |
|--------|------|--------|-------------------|
| `praxis_mcp_requests_total` | Counter | `method`, `protocol_version` | MCP requests by method (`tools/call`, `tools/list`, `initialize`, etc.) |
| `praxis_mcp_tool_calls_total` | Counter | `tool`, `cluster`, `transport_status` | Per-tool call counts with HTTP transport outcome |
| `praxis_mcp_tool_call_duration_seconds` | Summary | `tool`, `cluster` | Upstream round-trip latency per tool |
| `praxis_mcp_filter_rejections_total` | Counter | `method`, `reason` | Requests rejected by the filter |

---

## Architecture

![Praxis MCP Metrics Architecture](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/mcp-metrics/upstream-pr/architecture-metrics.png)

```
  M1 = praxis_mcp_requests_total         (on request arrival at MCP Filter)
  M2 = praxis_mcp_tool_calls_total       (on response at Router)
  M3 = praxis_mcp_tool_call_duration_seconds (on response, latency measurement)
  M4 = praxis_mcp_filter_rejections_total (on rejection at MCP Filter)
```

### Data flow

1. **Client** sends MCP JSON-RPC request (e.g. `tools/call` with tool `get_weather`)
2. **MCP filter** parses body, validates headers, increments `praxis_mcp_requests_total` **(M1)**
3. **Router** routes request to the matched backend cluster (weather-mcp, calculator-mcp, translator-mcp)
4. **On response**, filter records `praxis_mcp_tool_calls_total` **(M2)** and observes latency **(M3)**
5. **If rejected** (bad params, missing headers): increments `praxis_mcp_filter_rejections_total` **(M4)**
6. **Prometheus** scrapes `:9902/metrics` via ServiceMonitor every 15s
7. **Grafana** visualizes with 21-panel dashboard

---

## How the image is built

The Praxis image is built **entirely on the OCP cluster** — no local Rust toolchain needed.

### Build chain

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

---

## OCP deployment

### What gets deployed

```bash
bash deploy/deploy-all.sh
```

| Component | Purpose |
|-----------|---------|
| **Praxis AI Gateway** | Deployment with the patched image, OCP Route for HTTPS |
| **3 mock MCP servers** | weather-mcp (:3001), calculator-mcp (:3002), translator-mcp (:3003) |
| **Praxis config** | ConfigMap with 3 backend clusters, MCP filter enabled |
| **ServiceMonitor** | Prometheus scraping config for `:9902/metrics` |
| **Grafana dashboard** | 21-panel production dashboard for MCP metrics |

### Cluster details

- **Cluster:** `ai154.dl154.dfw.ocp.run` (OCP 4.17)
- **Namespace:** `praxis-mcp-test`
- **Praxis endpoint:** `https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run`

---

## Testing and verification

### Send test traffic

```bash
PRAXIS_URL="https://$(oc get route praxis-ai -n praxis-mcp-test -o jsonpath='{.spec.host}')"

# 1. Successful tool call → increments requests_total + tool_calls_total + duration
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

### Raw `/metrics` endpoint output

```bash
curl -sk https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run:9902/metrics | grep praxis_mcp
```

Output from the live cluster:

```
# TYPE praxis_mcp_requests_total counter
praxis_mcp_requests_total{method="tools/call",protocol_version="unknown"} 8
praxis_mcp_requests_total{method="tools/list",protocol_version="unknown"} 6
praxis_mcp_requests_total{method="tools/call",protocol_version="2025-11-25"} 30

# TYPE praxis_mcp_tool_calls_total counter
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",transport_status="ok"} 14
praxis_mcp_tool_calls_total{tool="translate",cluster="translator-mcp",transport_status="ok"} 6
praxis_mcp_tool_calls_total{tool="add",cluster="calculator-mcp",transport_status="ok"} 6
praxis_mcp_tool_calls_total{tool="multiply",cluster="calculator-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="forecast",cluster="weather-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="detect_language",cluster="translator-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="factorial",cluster="calculator-mcp",transport_status="ok"} 3

# TYPE praxis_mcp_filter_rejections_total counter
praxis_mcp_filter_rejections_total{method="tools/call",reason="invalid_params"} 9

# HELP praxis_mcp_tool_call_duration_seconds upstream round-trip time for MCP tool calls
# TYPE praxis_mcp_tool_call_duration_seconds summary
praxis_mcp_tool_call_duration_seconds_sum{tool="get_weather",cluster="weather-mcp"} 2.117071506
praxis_mcp_tool_call_duration_seconds_count{tool="get_weather",cluster="weather-mcp"} 14
praxis_mcp_tool_call_duration_seconds_sum{tool="translate",cluster="translator-mcp"} 3.570478103
praxis_mcp_tool_call_duration_seconds_count{tool="translate",cluster="translator-mcp"} 6
praxis_mcp_tool_call_duration_seconds_sum{tool="detect_language",cluster="translator-mcp"} 1.490611086
praxis_mcp_tool_call_duration_seconds_count{tool="detect_language",cluster="translator-mcp"} 3
praxis_mcp_tool_call_duration_seconds_sum{tool="add",cluster="calculator-mcp"} 0.114303136
praxis_mcp_tool_call_duration_seconds_count{tool="add",cluster="calculator-mcp"} 6
praxis_mcp_tool_call_duration_seconds_sum{tool="forecast",cluster="weather-mcp"} 0.337710703
praxis_mcp_tool_call_duration_seconds_count{tool="forecast",cluster="weather-mcp"} 3
praxis_mcp_tool_call_duration_seconds_sum{tool="factorial",cluster="calculator-mcp"} 0.095212128
praxis_mcp_tool_call_duration_seconds_count{tool="factorial",cluster="calculator-mcp"} 3
praxis_mcp_tool_call_duration_seconds_sum{tool="multiply",cluster="calculator-mcp"} 0.080548854
praxis_mcp_tool_call_duration_seconds_count{tool="multiply",cluster="calculator-mcp"} 3
```

### Metrics dashboard — live from OCP cluster

![Praxis MCP Metrics Dashboard](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/mcp-metrics/upstream-pr/metrics-dashboard.png)

| Metric | Live value |
|--------|-----------|
| `praxis_mcp_requests_total` | 44 (6 control plane + 38 data plane) |
| `praxis_mcp_tool_calls_total` | 38 (across 7 tools on 3 backends) |
| `praxis_mcp_tool_call_duration_seconds` (avg) | 205.4ms |
| `praxis_mcp_filter_rejections_total` | 9 (`invalid_params`) |

### Verify in Prometheus (OCP Console → Observe → Metrics)

```promql
praxis_mcp_tool_calls_total
```

```
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",transport_status="ok"} 14
praxis_mcp_tool_calls_total{tool="translate",cluster="translator-mcp",transport_status="ok"} 6
praxis_mcp_tool_calls_total{tool="add",cluster="calculator-mcp",transport_status="ok"} 6
praxis_mcp_tool_calls_total{tool="forecast",cluster="weather-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="detect_language",cluster="translator-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="factorial",cluster="calculator-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="multiply",cluster="calculator-mcp",transport_status="ok"} 3
```

### Verify ServiceMonitor is working

```bash
oc get servicemonitor -n praxis-mcp-test
oc get endpoints -n praxis-mcp-test praxis-ai-metrics
```

---

## Implementation details

### Source file: `src/metrics.rs` (~490 lines)

```rust
// 4 metric name constants
pub const METRIC_MCP_REQUESTS_TOTAL: &str = "praxis_mcp_requests_total";
pub const METRIC_MCP_TOOL_CALLS_TOTAL: &str = "praxis_mcp_tool_calls_total";
pub const METRIC_MCP_TOOL_CALL_DURATION: &str = "praxis_mcp_tool_call_duration_seconds";
pub const METRIC_MCP_FILTER_REJECTIONS_TOTAL: &str = "praxis_mcp_filter_rejections_total";

// Per-instance state stored in filter_state (not shared filter_metadata)
pub(crate) struct McpMetricsState { pub start: std::time::Instant, pub tool_name: String }

// 3 recording functions called from mod.rs
pub fn record_mcp_request(method: &str, protocol_version: &str) { ... }
pub fn record_tool_call_completed(tool: &str, cluster: &str, transport_status: &str, duration_seconds: f64) { ... }
pub fn record_filter_rejection(method: &str, reason: &str) { ... }
```

### Design decisions

- **Follows existing Praxis patterns** — same cardinality bounding approach as `llm_metrics.rs`, same label conventions, same test style
- **No new dependencies** — uses `metrics` crate already in `Cargo.toml`
- **Tool name capped at 64 chars** — prevents cardinality explosion from malicious inputs
- **`transport_status` mapped to `ok`/`error`** — not raw HTTP codes, to keep cardinality bounded; named to clarify it reflects HTTP transport outcome only, not JSON-RPC application success
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
| `diagnostics/check-metrics.sh` | ~100 | 8-layer end-to-end checker |
| `test/mock-mcp-server.py` | ~50 | Standalone mock for local testing |
| `test/simulate-traffic.sh` | ~40 | Traffic generator |

---

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>
