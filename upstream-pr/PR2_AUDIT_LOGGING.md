# PR #2: feat(mcp): structured audit logging for MCP tool calls

> Companion to PR #2030 (Prometheus metrics). Together they deliver **complete MCP observability** — metrics for dashboards and alerting, structured logs for compliance and incident triage.

## The problem

An enterprise AI gateway routing MCP tool calls has no MCP-specific observability today. When a `tools/call` to `query_database` fails, all you see is:

```
HTTP 500 in the access log — no tool name, no session, no tenant, no latency.
```

The operator can answer "did the proxy handle a request?" but cannot answer any of the questions that matter:

- **How much?** How many MCP tool calls are flowing through? What's the error rate? Which tools are hot?
- **How fast?** What's the p95 latency per tool? Is a specific backend degrading?
- **Who did what?** Which tenant called which tool, when, and what happened?
- **What went wrong?** Which specific call failed, and why was it rejected?

PR #2030 answers the first two. This PR answers the last two. Together they close the gap.

---

## What we built — two PRs, one observability story

| Layer | PR | What it answers | Mechanism |
|-------|-----|----------------|-----------|
| **Metrics** | #2030 | How many? How fast? What error rate? | 4 Prometheus metrics on `:9902/metrics` |
| **Audit logs** | This PR | Who called what, when, with what result? | 3 structured `tracing::info!` events → Loki |

### The 4 Prometheus metrics (PR #2030)

| Metric | Type | Labels | Question it answers |
|--------|------|--------|-------------------|
| `praxis_mcp_requests_total` | Counter | method, protocol_version | How many MCP requests by method? |
| `praxis_mcp_tool_calls_total` | Counter | tool, cluster, transport_status | Which tools are called, on which backend, how often? |
| `praxis_mcp_tool_call_duration_seconds` | Histogram | tool, cluster | How fast is each tool? What's the p50/p95/p99? |
| `praxis_mcp_filter_rejections_total` | Counter | method, reason | How many requests are being rejected, and why? |

### The 3 audit log events (this PR)

| Event | Phase | When emitted | Key fields |
|-------|-------|-------------|------------|
| `mcp.call.completed` | Response | `tools/call` upstream responds | tool name, status, latency, cluster, tenant |
| `mcp.call.rejected` | Request | Filter rejects before upstream | rejection reason, method, tenant |
| `mcp.call.initiated` | Request | Non-tool methods pass filter | method, session ID, tenant |

### Why both layers matter

Metrics tell you *something is wrong*. Audit logs tell you *exactly what happened*.

Here's what that looks like with real data from our OCP test cluster. Both data sources feed a [unified Grafana dashboard](#grafana-dashboard--the-unified-view) with four sections — Sections 1–3 are powered by Prometheus (PR #2030), Section 4 by Loki (this PR):

**What the Prometheus panels (Tool Intelligence) tell you:**

![Tool Intelligence — Prometheus panels showing tool call distribution and latency per tool](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section2-tool-intelligence.jpg)

The Tool Call Distribution panel says `get_weather=3`. The Avg Latency by Tool panel says `get_weather=0.134s`. Useful — you know get_weather is the active tool and what its average latency looks like. But you can't dig deeper. You can't ask "which of those 3 calls was slowest?" or "who sent them?" The metric just says "3" — it's a running total.

**What the Loki panels (Audit Trail) tell you:**

![Audit Trail — Loki panels showing individual audit events with tenant, tool, duration, and outcome](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section4-audit-trail.jpg)

The Recent Audit Events panel shows each individual call. One entry reads: `mcp_name="get_weather"`, `mcp_duration_ms=153`, `tenant="loki-verify"`, `mcp_cluster="weather-mcp"`, `mcp_upstream_status=200`. That's one specific call — you know *who* made it, *when*, *how long* it took, and *what happened*.

Scroll through the entries and the detail emerges: three completed calls with latencies of 153ms, 118ms, and 130ms — spread across tenants `loki-verify` and `test-tenant-1`. The Avg Tool Latency stat panel shows 0.13s — but only the audit log tells you that `test-tenant-1` made two of those three calls.

**Rejections tell the same story.** Prometheus says "1 rejection: invalid_params." The Rejections by Tenant panel in Loki says `test-tenant-2=1`. Without the audit log, you'd have no idea which tenant was responsible — the Prometheus metric doesn't carry a tenant label.

Without metrics, you don't know something is wrong. Without audit logs, you can't pinpoint who was affected or build the incident timeline.

---

## Grafana dashboard — the unified view

Both PRs feed a single Grafana dashboard that tells the MCP observability story in four sections. Here's the full dashboard from our live OCP test cluster:

### Section 1 — MCP Traffic (what Praxis sees)

> *"How much MCP traffic is flowing through, and how healthy is it?"*

![Section 1 — MCP Traffic: stat panels showing total requests, tool calls, rejections, and avg latency, plus method distribution and rejection reason pie charts](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section1-mcp-traffic.jpg)

| Panel | Data source | Query |
|-------|------------|-------|
| Total MCP Requests | Prometheus | `sum(praxis_mcp_requests_total)` |
| Total Tool Calls | Prometheus | `sum(praxis_mcp_tool_calls_total)` |
| Requests Rejected | Prometheus | `sum(praxis_mcp_filter_rejections_total)` |
| Avg Tool Latency | Prometheus | `sum(duration_seconds_sum) / sum(duration_seconds_count)` |
| Requests by MCP Method | Prometheus | `sum by (method) (praxis_mcp_requests_total)` |
| Rejection Reasons | Prometheus | `sum by (reason) (praxis_mcp_filter_rejections_total)` |
| Rejection Details | Prometheus | method × reason breakdown table |

### Section 2 — Tool Intelligence (which tools, how often, how fast)

> *"Which tools are hot? Which backends are they hitting? What's the latency profile?"*

![Section 2 — Tool Intelligence: bar gauges showing tool call distribution, pie chart for cluster distribution, p95 and avg latency per tool](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section2-tool-intelligence.jpg)

| Panel | Data source | Query |
|-------|------------|-------|
| Tool Call Distribution | Prometheus | `sum by (tool) (praxis_mcp_tool_calls_total)` |
| Tool Calls by MCP Server | Prometheus | `sum by (cluster) (praxis_mcp_tool_calls_total)` |
| Tool × Status Breakdown | Prometheus | tool × transport_status table |
| P95 Latency by Tool | Prometheus | `histogram_quantile(0.95, ... by (tool, le))` |
| Avg Latency by Tool | Prometheus | `sum by (tool) (duration_sum) / sum by (tool) (duration_count)` |

### Section 3 — Traffic Over Time (spot spikes and anomalies)

> *"Is anything changing? Are we seeing spikes, degradation, or new patterns?"*

![Section 3 — Traffic Over Time: stacked bar charts for requests and tool calls over time, plus p50/p95/p99 latency curves](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section3-traffic-over-time.jpg)

| Panel | Data source | Query |
|-------|------------|-------|
| MCP Requests Over Time | Prometheus | `sum by (method) (increase(praxis_mcp_requests_total[$__rate_interval]))` |
| Tool Calls Over Time | Prometheus | `sum by (tool) (increase(praxis_mcp_tool_calls_total[$__rate_interval]))` |
| Rejections Over Time | Prometheus | `sum by (reason) (increase(praxis_mcp_filter_rejections_total[$__rate_interval]))` |
| Tool Latency Over Time (p50/p95/p99) | Prometheus | `histogram_quantile(0.50/0.95/0.99, sum(rate(duration_bucket[5m])) by (le))` |

### Section 4 — Audit Trail (compliance and incident triage) ← this PR

> *"What exactly happened? Show me the individual events."*

![Section 4 — Audit Trail: bar gauge of audit events by outcome, pie chart of rejection reasons, bar gauge of rejections by tenant, audit volume time series, and raw log stream](https://raw.githubusercontent.com/redhat-telco-guy/praxis-mcp-observability/feat/audit-logging/upstream-pr/screenshots/section4-audit-trail.jpg)

| Panel | Data source | Query |
|-------|------------|-------|
| Audit Events by Outcome | Loki | `sum by (outcome) (count_over_time({...} |= "mcp.call." | json ...))` |
| Rejections by Reason | Loki | `sum by (reason) (count_over_time({...} |= "rejected" | json ...))` |
| Rejections by Tenant | Loki | `sum by (tenant) (count_over_time({...} |= "rejected" | json ...))` |
| Audit Volume Over Time | Loki | `count_over_time({...} |= "mcp.call." [$__interval])` |
| Recent Audit Events | Loki | Full structured log stream with expandable JSON detail |

The first three sections use **Prometheus** (PR #2030). The fourth section uses **Loki** (this PR). Together, the dashboard flows from aggregate health → tool-level intelligence → temporal patterns → individual event forensics.

---

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │          OpenShift Cluster                   │
                    │                                             │
  ┌──────────┐     │  ┌───────────────────┐     ┌─────────────┐  │
  │  Client   │────▶│  │  Praxis AI Gateway │────▶│ MCP backends│  │
  │ (curl/SDK)│     │  │                   │     │ (3 servers) │  │
  └──────────┘     │  │  ┌─────────────┐  │     └─────────────┘  │
                    │  │  │ MCP Filter  │  │                      │
                    │  │  │             │  │                      │
                    │  │  │ metrics.rs  │◀─┼── PR #2030: 4 prom  │
                    │  │  │             │  │   metrics            │
                    │  │  │ audit.rs    │◀─┼── This PR: 3 struct  │
                    │  │  │             │  │   log events         │
                    │  │  └─────────────┘  │                      │
                    │  │                   │                      │
                    │  │  :9902/metrics ───┼──▶ Prometheus ──┐    │
                    │  │                   │                 │    │
                    │  │  stdout ──────────┼──▶ Vector ──▶ Loki  │
                    │  │  (audit events)   │   (CLF)     │  │    │
                    │  └───────────────────┘             │  │    │
                    │                                    │  │    │
                    │  ┌──────────────────────────────┐  │  │    │
                    │  │          Grafana              │  │  │    │
                    │  │  Sections 1-3: Prometheus ◀───┘  │    │
                    │  │  Section 4:    Loki ◀─────────────┘    │
                    │  └──────────────────────────────┘         │
                    └─────────────────────────────────────────────┘
```

### Audit log pipeline

```
Praxis pod stdout
       │
       ▼
  ClusterLogForwarder (Vector)
       │
       ├── parse-json filter (parse container log JSON)
       ├── audit-only filter (drop non mcp.call.* lines)
       └── prune-fields filter (strip noisy k8s annotations)
       │
       ▼
  LokiStack (openshift-logging)
       │
       ├──▶ Grafana (Loki datasource, Section 4 audit panels)
       ├──▶ OCP Console (Observe → Logs)
       └──▶ ACS (StackRox runtime policy alerts)
```

---

## Two-phase audit model

The audit filter uses `filter_state` to carry metadata across the request/response boundary:

```
  Request arrives
       │
       ├── Is it tools/call?
       │     ├── YES: passes validation?
       │     │    ├── YES: store AuditState (tool, tenant, start_time)
       │     │    │         in filter_state ──────────────────────────┐
       │     │    │                                                   │
       │     │    └── NO:  emit_rejected() ──▶ mcp.call.rejected     │
       │     │                                                        │
       │     └── NO (tools/list, initialize, ping...):               │
       │          emit_non_tool() ──▶ mcp.call.initiated             │
       │                                                              │
       ▼                                                              │
  Response arrives (tools/call only)                                 │
       │                                                              │
       └── Read back AuditState ◀─────────────────────────────────────┘
           Compute latency from start_time
           emit_completed() ──▶ mcp.call.completed
```

### Structured fields per event

```json
{
  "timestamp": "2026-11-23T14:32:47.028Z",
  "level": "INFO",
  "target": "praxis_ai::mcp_audit",
  "fields": {
    "message":              "mcp.call.completed",
    "log_type":             "mcp_audit",
    "mcp_method":           "tools/call",
    "mcp_name":             "get_weather",
    "mcp_session_id":       "sess_abc123",
    "mcp_protocol_version": "2026-11-05",
    "mcp_outcome":          "ok",
    "mcp_upstream_status":  200,
    "mcp_duration_ms":      101,
    "mcp_cluster":          "weather-mcp",
    "tenant":               "acme-corp"
  }
}
```

---

## OCP testing — live results

### Test setup

Deployed on a fresh AWS OCP 4.17 cluster with a mock MCP backend (weather). The `install.sh` script builds Praxis from upstream source with both PRs patched, deploys the full stack, and runs verification requests covering all three audit event types.

### Live Prometheus metrics (`:9902/metrics`)

```
# All 4 metrics emitting:
praxis_mcp_requests_total{method="tools/call",protocol_version="2024-11-05"} 4
praxis_mcp_requests_total{method="tools/list",protocol_version="2024-11-05"} 1
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",transport_status="ok"} 3
praxis_mcp_tool_call_duration_seconds_bucket{tool="get_weather",cluster="weather-mcp",le="0.25"} 3
praxis_mcp_filter_rejections_total{method="tools/call",reason="invalid_params"} 1
```

### Live audit log events (pod stdout → Loki)

**Completed tool call** (200 OK, 130ms):
```
mcp.call.completed log_type="mcp_audit" mcp_method="tools/call"
  mcp_name="get_weather" mcp_outcome="ok" mcp_upstream_status=200
  mcp_duration_ms=130 mcp_cluster="weather-mcp" tenant="test-tenant-1"
```

**Rejected call** (missing tool name):
```
mcp.call.rejected log_type="mcp_audit" mcp_method="tools/call"
  mcp_outcome="rejected" mcp_rejection_reason="invalid_params"
  tenant="test-tenant-2"
```

**Initiated non-tool** (tools/list):
```
mcp.call.initiated log_type="mcp_audit" mcp_method="tools/list"
  mcp_outcome="initiated" tenant="test-tenant-3"
```

---

## Implementation details

### Source: `filters/src/agentic/mcp/audit.rs`

| Component | Detail |
|-----------|--------|
| Emit functions | `emit_rejected()`, `emit_non_tool()`, `emit_completed()` |
| Cross-phase state | `AuditState` struct in `filter_state` (start Instant, method, tool name, session ID, protocol version, tenant) |
| Tracing target | `praxis_ai::mcp_audit` — dedicated target accepted by `praxis_ai=info` EnvFilter |
| Log isolation | `log_type = "mcp_audit"` field for log collector filtering |
| Dependencies | None new — `tracing` already in `Cargo.toml` |

### Design decisions

**Why structured tracing, not a separate output?** Structured fields in the existing tracing pipeline are cheaper than a separate I/O path. Log collectors (Vector, Fluentd) filter on `log_type` with zero overhead.

**Why `filter_state` for cross-phase carry-over?** The typed `filter_state` API (keyed by `current_filter_id`) is the Praxis-idiomatic way to carry per-request state across the request → response boundary. No metadata key collisions, no string parsing.

**Why `mcp_audit` tracing target?** The Praxis tracing subscriber's `EnvFilter` matches `praxis_ai=info`, which accepts targets starting with `praxis_ai::` — this ensures audit events are emitted at the standard `INFO` level without extra configuration.

**Log metadata, never content.** Following Praxis conventions, audit events carry sizes, counts, IDs, status codes, and bounded classification fields. Request bodies, tool arguments, and provider error messages stay out of logs.

### Why `metrics.rs` has a one-line change

This PR introduces `AuditState` as a superset of `McpMetricsState` — it carries the same `start` and `tool_name` fields (for metrics) plus `method`, `session_id`, `protocol_version`, and `tenant` (for audit). All `McpMetricsState` usage in `mod.rs` is replaced by `AuditState`, leaving the struct unused. The struct is retained so the metrics PR (#2030) can be reviewed and merged independently. Once both PRs land, the struct and annotation can be removed. The only change to `metrics.rs` is adding `#[allow(dead_code)]` above `McpMetricsState`.

### Unit tests

| Test | Validates |
|------|-----------|
| `emit_rejected_uses_audit_target` | Rejected event fires with correct tracing target |
| `emit_non_tool_uses_audit_target` | Initiated event fires correctly |
| `emit_completed_ok_uses_audit_target` | Completed (200) event fires |
| `emit_completed_error_uses_audit_target` | Completed (500) event fires |
| `duration_ms_is_sane` | Latency computation doesn't overflow |

---

## Files changed

| File | Lines | Purpose |
|------|-------|---------|
| `filters/src/agentic/mcp/audit.rs` | +345 | New file: 3 emit functions, `AuditState`, unit tests |
| `filters/src/agentic/mcp/mod.rs` | +60/−24 | Wiring: `mod audit`, emit calls in request/response phases |
| `filters/src/agentic/mcp/metrics.rs` | +8 | `#[allow(dead_code)]` on `McpMetricsState` (see [rationale](#why-metricsrs-has-a-one-line-change)) |

---

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>
