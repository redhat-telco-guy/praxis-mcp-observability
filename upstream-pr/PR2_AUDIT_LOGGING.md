# PR #2: feat(mcp): structured audit logging for MCP tool calls

> Builds on PR #1 (Prometheus metrics). Both patches are applied to the same image.

## What this PR adds

**Structured audit logging** for every MCP tool call flowing through the Praxis AI gateway. While PR #1 (Prometheus metrics) answers "how many calls at what rate", this PR answers **"which specific call, by whom, to what tool, with what result"**.

| Capability | What it answers | How |
|------------|----------------|-----|
| **PR #1 — Prometheus metrics** | How many calls? What rate? What error rate? | 4 counters/histograms on `:9902/metrics` |
| **PR #2 — Audit logging** (this PR) | Which specific call, by whom, to what tool, with what result? | Structured `tracing::info!` events → Loki → Grafana |

Together they give **complete MCP observability** — Prometheus for dashboards and alerting, structured logs for compliance and incident triage.

---

## Why this matters

For a `tools/call` to `query_database` that fails, today you have:
```
HTTP 500 in the access log — no tool name, no session, no tenant, no latency.
```

After this change you have:
```json
{
  "message": "mcp.call.completed",
  "log_type": "mcp_audit",
  "mcp_method": "tools/call",
  "mcp_name": "query_database",
  "mcp_outcome": "error",
  "mcp_upstream_status": 500,
  "mcp_duration_ms": 1243,
  "mcp_cluster": "analytics-mcp",
  "tenant": "acme-corp"
}
```

This is what compliance teams ask for and what SREs need for incident triage. Competing gateways (Kong AI Gateway, Portkey) provide per-call structured audit logs as a standard feature.

---

## Architecture

![Praxis MCP Audit Logging Architecture](upstream-pr/architecture-audit.png)

### Log pipeline

`Praxis pod stdout` → `ClusterLogForwarder (Vector)` → `LokiStack` → `Grafana / OCP Console / ACS`

The ClusterLogForwarder applies three Vector filters: **parse-json** (parse container log JSON), **audit-only** (drop non `mcp.call.*` lines), and **prune-fields** (strip noisy k8s annotations).

---

## Audit events emitted

Three structured log events per MCP request lifecycle:

| Event | Phase | When | Key fields |
|-------|-------|------|------------|
| `mcp.call.completed` | Response | `tools/call` upstream responds | tool name, status, latency, cluster, tenant |
| `mcp.call.rejected` | Request | Filter rejects before upstream | rejection reason, tenant |
| `mcp.call.initiated` | Request | Non-tool methods pass filter | method, tenant |

### Two-phase audit model

```
  Request arrives
       │
       ├── Is it tools/call?
       │     ├── YES: passes validation?
       │     │    ├── YES: store metadata (tool, tenant, start_time)
       │     │    │         in HttpFilterContext ──────────────────┐
       │     │    │                                                │
       │     │    └── NO:  emit_rejected() ──▶ mcp.call.rejected  │
       │     │                                                     │
       │     └── NO (tools/list, initialize, ping...):            │
       │          emit_non_tool() ──▶ mcp.call.initiated          │
       │                                                           │
       ▼                                                           │
  Response arrives (tools/call only)                              │
       │                                                           │
       └── Read back stored metadata ◀────────────────────────────┘
           Compute latency from start_time
           emit_completed() ──▶ mcp.call.completed
```

### All fields emitted

```json
{
  "timestamp": "2026-11-16T20:32:47.028Z",
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
    "tenant":               "test-tenant-1"
  }
}
```

---

## How the image is built

This PR adds `audit.rs` alongside the existing `metrics.rs` from PR #1. Both are patched into the same upstream Praxis source and compiled into a single image.

### Build chain

![OCP Build Pipeline](upstream-pr/build-chain.png)

This PR adds steps 3-4 on top of PR #1's pipeline: copy `audit.rs`, run `patch-audit-mod-rs.py` to wire `emit_rejected()`, `emit_non_tool()`, `emit_completed()` and metadata storage into `mod.rs`, plus post-patch fixups (startup log, lint fixes, Containerfile patches for OCP Buildah).

### Build command

```bash
# install.sh handles everything — clone, patch, build, deploy
PRAXIS_AI_DIR=/path/to/praxis-proxy/ai ./install.sh
```

The `install.sh` script:
1. Resets the upstream checkout to clean state
2. Clones `praxis-mcp-observability` for Gap 1 (metrics) patches
3. Copies `metrics.rs` and runs `patch-mod-rs.py`
4. Copies `audit.rs` and runs `patch-audit-mod-rs.py`
5. Runs post-patch fixups (startup log, lint fixes, Containerfile patches)
6. Triggers OCP BuildConfig (~12-15 min Rust compilation)
7. Deploys the full stack

---

## OCP deployment

### What gets deployed (single `./install.sh` command)

| Component | What it does |
|-----------|-------------|
| **Praxis AI Gateway** | Built on-cluster from upstream source + both patches |
| **3 mock MCP servers** | weather-mcp, calculator-mcp, translator-mcp |
| **ClusterLogForwarder** | Routes `mcp.call.*` audit events from pod stdout → LokiStack via Vector |
| **LokiStack tuning** | `maxConcurrentQueriesPerTenant: 32` for reliable Grafana queries |
| **Grafana + Loki datasource** | Auto-provisioned with SA bearer token auth (OCP Logging 6.7 `loki.grafana.com` API) |
| **Grafana dashboard** | 3-panel audit dashboard using LogQL `regexp` extraction (v8) |
| **ACS (StackRox)** | Runtime policy detecting agent-loop anomalies (>50 calls/session/5min) |
| **ACM** | Fleet governance ensuring CLF is deployed on all managed clusters |
| **OCP Console UIPlugin** | Enables Observe → Logs for audit event browsing |
| **ServiceMonitor** | Prometheus scraping for PR #1 metrics |

### Cluster details

- **Cluster:** `ai154.dl154.dfw.ocp.run` (OCP 4.17)
- **Namespace:** `praxis-mcp-test`
- **Praxis endpoint:** `https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run`
- **Grafana:** `https://grafana-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run` (admin / praxis-audit)

---

## Testing and verification

### Test traffic (3 curl commands)

```bash
PRAXIS_URL="https://$(oc get route praxis-ai -n praxis-mcp-test -o jsonpath='{.spec.host}')"

# 1. Completed tool call → mcp.call.completed
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: test-tenant-1" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Dallas"}}}'

# 2. Rejected call → mcp.call.rejected
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: test-tenant-2" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{}}'

# 3. Initiated non-tool → mcp.call.initiated
curl -sk -X POST "$PRAXIS_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: test-tenant-3" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
```

### Verify in pod logs

```bash
oc logs -l app=praxis-ai -n praxis-mcp-test --since=30s | grep mcp.call
```

Pod log output from `oc logs -l app=praxis-ai -n praxis-mcp-test --since=30s | grep mcp.call`:

```
2026-11-16T20:32:47.028Z INFO praxis_ai::mcp_audit: mcp.call.completed log_type="mcp_audit" mcp_method="tools/call" mcp_name="get_weather" mcp_outcome="ok" mcp_upstream_status=200 mcp_duration_ms=101 mcp_cluster="weather-mcp" tenant="test-tenant-1"
2026-11-16T20:32:46.891Z INFO praxis_ai::mcp_audit: mcp.call.rejected log_type="mcp_audit" mcp_method="tools/call" mcp_outcome="rejected" mcp_rejection_reason="invalid_params" tenant="test-tenant-2"
2026-11-16T20:32:45.743Z INFO praxis_ai::mcp_audit: mcp.call.initiated log_type="mcp_audit" mcp_method="tools/list" mcp_outcome="initiated" tenant="test-tenant-3"
```

### Verification script output

```
=== Praxis MCP Audit Log Verification ===
    Project:   praxis-mcp-test
    Endpoint:  https://praxis-ai-praxis-mcp-test.apps.ai154.dl154.dfw.ocp.run/mcp

--- Test 1: valid tools/call → mcp.call.completed ---
  PASS  mcp.call.completed event present in pod logs
  PASS  log_type=mcp_audit present in pod logs
  PASS  Audit event has all 4 expected fields (method, outcome, duration_ms, tenant)

--- Test 2: invalid tools/call (no name) → mcp.call.rejected ---
  PASS  mcp.call.rejected event present in pod logs

--- Test 3: tools/list → mcp.call.initiated ---
  PASS  mcp.call.initiated event present in pod logs

--- Test 4: Loki pipeline — audit events are flowing ---
  PASS  Audit events present in Loki stream
  PASS  MCP call events visible in Loki

--- Test 5: audit events are isolated (log_type field is set) ---
  PASS  3 audit event(s) found in last 60s (out of 47 total log lines)

=== Summary ===
All tests passed.
```

### Grafana audit dashboard — live data

**Grafana audit dashboard** (live from OCP cluster `ai154.dl154.dfw.ocp.run`):

![Praxis MCP Audit Dashboard](upstream-pr/audit-dashboard.png)

The dashboard uses 3 LogQL queries (not 6 — we discovered that OCP Logging 6.7's LokiStack gateway drops concurrent queries beyond its default limit, so we consolidated using `regexp` extraction):

| Panel | Query | Live result |
|-------|-------|-------------|
| Audit Events by Outcome | `sum by (outcome) (count_over_time({...} \|= "mcp.call." \| regexp "mcp\\.call\\.(?P<outcome>completed\|rejected\|initiated)" [$__range]))` | completed=4, rejected=3, initiated=3 |
| Audit Volume by Pod | `sum by (kubernetes_pod_name) (count_over_time({...} \|= "mcp.call." [$__range]))` | praxis-ai-678f64dfb4-vxp8b → 10 |
| Recent Audit Events | `{kubernetes_namespace_name="praxis-mcp-test"} \|= "mcp.call."` | Full log stream with expandable detail |

### Grafana Explore — query verification

Grafana Explore query verification — `{kubernetes_namespace_name="praxis-mcp-test"} |= "mcp.call."` returns 90+ events with structured fields visible in the log stream.

### Live audit events from the cluster

**Completed tool call** (`tools/call` → `get_weather` → 200 OK, 101ms):
```
mcp.call.completed log_type="mcp_audit" mcp_method="tools/call"
  mcp_name="get_weather" mcp_outcome="ok" mcp_upstream_status=200
  mcp_duration_ms=101 mcp_cluster="weather-mcp" tenant="test-tenant-1"
```

**Rejected call** (missing tool name):
```
mcp.call.rejected log_type="mcp_audit" mcp_method="tools/call"
  mcp_outcome="rejected" mcp_rejection_reason="invalid_params"
  tenant="test-tenant-2"
```

**Initiated non-tool** (`tools/list`):
```
mcp.call.initiated log_type="mcp_audit" mcp_method="tools/list"
  mcp_outcome="initiated" tenant="test-tenant-3"
```

---

## Implementation details

### Source file: `src/audit.rs` (411 lines)

Three emit functions, 6 metadata keys for cross-phase carry-over, 6 unit tests:

```rust
// Emit functions
pub(crate) fn emit_rejected(method, name, session_id, protocol_version, tenant, reason)
pub(crate) fn emit_non_tool(method, session_id, protocol_version, tenant)
pub(crate) fn emit_completed(tool, cluster, method, session_id, protocol_version, tenant, status, start_ns)

// Metadata keys (mcp.audit.* prefix to avoid collisions with metrics module)
pub(crate) const META_AUDIT_START_NS: &str = "mcp.audit.start_ns";
pub(crate) const META_AUDIT_METHOD: &str = "mcp.audit.method";
pub(crate) const META_AUDIT_TOOL: &str = "mcp.audit.tool";
pub(crate) const META_AUDIT_SESSION_ID: &str = "mcp.audit.session_id";
pub(crate) const META_AUDIT_PROTOCOL_VERSION: &str = "mcp.audit.protocol_version";
pub(crate) const META_AUDIT_TENANT: &str = "mcp.audit.tenant";
```

### Unit tests (6 tests)

| Test | What it validates |
|------|-------------------|
| `emit_rejected_uses_audit_target` | Rejected event fires with correct tracing target |
| `emit_non_tool_uses_audit_target` | Initiated event fires correctly |
| `emit_completed_ok_uses_audit_target` | Completed (200) event fires |
| `emit_completed_error_uses_audit_target` | Completed (500) event fires |
| `request_start_ns_is_nonzero` | Epoch-nanos returns valid time |
| `duration_ms_is_sane` | Latency computation doesn't overflow |

### Design decisions

**Why `log_type = "mcp_audit"` field?**
Structured fields in the existing tracing pipeline are cheaper than a separate output. Log collectors (Vector, Fluentd) filter on `log_type` with zero overhead. No new I/O paths.

**Why `target: "praxis_ai::mcp_audit"`?**
The Praxis tracing subscriber's `EnvFilter` matches `praxis_ai=info`, which accepts targets starting with `praxis_ai::` but not `praxis_ai_` (the filters crate's module path prefix).

**Why `mcp.audit.*` metadata key prefix?**
Avoids collisions with the metrics module's `mcp.*` and `json_rpc.*` keys — both modules coexist in the same filter.

**Why 3 LogQL queries instead of 6 in Grafana?**
OCP Logging 6.7's LokiStack gateway has a default `maxConcurrentQueriesPerTenant` of ~5. We discovered (through debugging) that firing 6+ queries simultaneously caused random panels to show "No data". Fixed two ways: raised the limit to 32, and consolidated queries using LogQL `regexp` extraction.

**No new dependencies.** `tracing` is already in `Cargo.toml`.

---

## Files in this PR

### Rust source (upstream contribution)

| File | Lines | Purpose |
|------|-------|---------|
| `src/audit.rs` | 411 | 3 emit functions, 6 metadata keys, 6 unit tests |
| `src/patch-audit-mod-rs.py` | ~100 | Build-time patcher wiring audit into mod.rs |

### OCP deployment

| File | Purpose |
|------|---------|
| `install.sh` | Single-command full-stack deployer (builds image, deploys everything) |
| `deploy/cluster-log-forwarder.yaml` | Vector pipeline → LokiStack with audit-only filter |
| `deploy/grafana-audit-dashboard.json` | 3-panel Grafana dashboard (v8) |
| `deploy/acs-runtime-policy.json` | ACS anomaly detection (>50 tool calls/session/5min) |
| `deploy/acm-audit-policy.yaml` | ACM fleet governance (enforce CLF on all clusters) |

### Testing

| File | Purpose |
|------|---------|
| `test/verify-audit-logs.sh` | 5-test end-to-end verification script |

### Upstream PR materials

| File | Purpose |
|------|---------|
| `upstream-pr/AUDIT_GITHUB_ISSUE.md` | Ready-to-file GitHub issue at praxis-proxy/ai |
| `upstream-pr/AUDIT_PR_DESCRIPTION.md` | Ready-to-paste upstream PR description |
| `upstream-pr/AUDIT_MOD_RS_PATCHES.md` | Documented mod.rs patch call sites |

---

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>
