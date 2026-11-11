# Praxis MCP Observability

**Adding Prometheus metrics to the MCP filter in [Praxis](https://github.com/praxis-proxy/ai) — so you can see what your MCP tools are actually doing.**

Praxis is a Rust-native HTTP proxy (CNCF Sandbox, maintained by Red Hat) that routes AI traffic — LLM inference, A2A agents, and MCP tool calls. It already ships ~71 Prometheus metrics for HTTP, LLM inference, and intelligent routing. But the MCP filter? Zero metrics. It parses JSON-RPC, validates headers, routes tool calls to backends — all invisible to your monitoring stack.

This project adds 4 MCP-specific Prometheus metrics, an interactive demo dashboard, and everything you need to deploy and test on OpenShift.

## What This Adds

### The 4 Metrics

| Metric | Type | Labels | What It Tells You |
|--------|------|--------|-------------------|
| `praxis_mcp_requests_total` | Counter | `method`, `protocol_version` | How many MCP requests by method (tools/list, tools/call, etc.) and protocol version |
| `praxis_mcp_tool_calls_total` | Counter | `tool`, `cluster`, `status` | Per-tool call counts with success/failure — which tools are hot, which are failing |
| `praxis_mcp_tool_call_duration_seconds` | Histogram | `tool`, `cluster` | Upstream round-trip time per tool — find slow backends before users notice |
| `praxis_mcp_filter_rejections_total` | Counter | `method`, `reason` | Requests rejected by the filter — misconfiguration, attacks, bad clients |

These follow the same patterns as Praxis's existing `llm_metrics.rs` — same cardinality bounding, same label conventions, same test style.

### Why This Matters

Without these metrics, you're flying blind on MCP traffic:

- **"Which tools are my agents actually calling?"** — No idea. You see HTTP 200s but not that `translate` was called 500x while `get_weather` was called twice.
- **"Why is my agent slow?"** — Could be the LLM, could be the tool backend. Without per-tool latency, you can't tell.
- **"Is someone sending garbage?"** — The filter rejects invalid requests, but nobody knows because it doesn't count them.

Competing gateways (Kong AI Gateway, Portkey) already ship tool-level metrics. This brings Praxis to parity.

## Architecture

```
                                    ┌─────────────────────────────────────────┐
                                    │          OpenShift Cluster              │
                                    │                                        │
  ┌──────────┐    HTTPS    ┌────────┴──────────┐                             │
  │  Client  │────────────>│   Praxis Proxy    │                             │
  │ (curl,   │             │                   │                             │
  │  agent)  │             │  MCP Filter:      │     ┌───────────────────┐   │
  └──────────┘             │  ┌─────────────┐  │────>│  weather-mcp      │   │
                           │  │ Parse JSON  │  │     │  (mock, port 3001)│   │
                           │  │ RPC body    │  │     └───────────────────┘   │
                           │  ├─────────────┤  │                             │
                           │  │ Validate    │  │     ┌───────────────────┐   │
                           │  │ headers     │  │────>│  calculator-mcp   │   │
                           │  ├─────────────┤  │     │  (mock, port 3002)│   │
                           │  │ Record      │  │     └───────────────────┘   │
                           │  │ metrics ◄───┼──┼─── NEW! 4 counters         │
                           │  ├─────────────┤  │     ┌───────────────────┐   │
                           │  │ Route to    │  │────>│  translator-mcp   │   │
                           │  │ backend     │  │     │  (mock, port 3003)│   │
                           │  └─────────────┘  │     └───────────────────┘   │
                           │                   │                             │
                           │  :9902/metrics ───┼──┐                          │
                           └───────────────────┘  │                          │
                                                  │                          │
                           ┌───────────────────┐  │  ┌───────────────────┐   │
                           │   ServiceMonitor  │──┘  │   Prometheus      │   │
                           │   (scrapes :9902) │────>│   (user-workload) │   │
                           └───────────────────┘     └───────────────────┘   │
                                                                             │
                           ┌───────────────────┐                             │
                           │  Demo Dashboard   │  Reads /metrics from Praxis │
                           │  (httpd, 5 tabs)  │  Shows live counters        │
                           └───────────────────┘                             │
                                    └────────────────────────────────────────┘
```

### Data Flow

1. **Client** sends an MCP JSON-RPC request (e.g., `tools/call` with tool name `get_weather`)
2. **Praxis MCP filter** parses the body, validates headers, and records metrics:
   - Increments `praxis_mcp_requests_total{method="tools/call"}`
   - Stores start time in request metadata for latency measurement
3. **Praxis routes** the request to the correct backend (weather-mcp, calculator-mcp, etc.)
4. **On response**, the filter records:
   - `praxis_mcp_tool_calls_total{tool="get_weather", cluster="weather-mcp", status="ok"}`
   - `praxis_mcp_tool_call_duration_seconds{tool="get_weather"}` with the measured latency
5. **If rejected** (missing tool name, bad headers, invalid JSON-RPC):
   - `praxis_mcp_filter_rejections_total{method="tools/call", reason="invalid_params"}`
6. **Prometheus** scrapes `:9902/metrics` via the ServiceMonitor
7. **Dashboard** queries the same endpoint and shows live numbers

### Rejection Reasons (Closed Set)

| Reason | When It Fires |
|--------|--------------|
| `invalid_params` | `tools/call` sent without a tool name |
| `header_mismatch` | `Mcp-Name` header doesn't match the body |
| `missing_header` | Required MCP header is absent (when `missing: reject` is configured) |
| `invalid_jsonrpc` | Body fails JSON-RPC parsing entirely |

## Repository Structure

```
praxis-mcp-observability/
├── README.md                          # This file
├── LICENSE                            # Apache 2.0
│
├── src/                               # The upstream contribution (what goes into the PR)
│   ├── metrics.rs                     # New file: 4 Prometheus metrics with cardinality bounding
│   └── patch-mod-rs.py                # Build-time patcher: wires metrics into mod.rs
│
├── build/                             # Container image build
│   ├── Containerfile                  # Multi-stage Rust build for OCP
│   └── build-on-ocp.sh               # One-command OCP build (creates ImageStream + BuildConfig)
│
├── deploy/                            # OCP deployment (one-command setup)
│   ├── deploy-all.sh                  # Self-contained deployer (embeds all manifests)
│   ├── mock-servers.yaml              # 3 mock MCP servers (weather, calculator, translator)
│   ├── servicemonitor.yaml            # Prometheus scraping config
│   └── grafana-dashboard.json         # Production Grafana dashboard
│
├── dashboard/                         # Interactive demo dashboard
│   └── dashboard.html                 # 5-tab HTML: Metrics, Test Lab, Architecture,
│                                      #   Prometheus walkthrough, Gap Analysis
│
├── diagnostics/                       # Troubleshooting
│   └── check-metrics.sh              # 8-layer end-to-end metrics pipeline checker
│
├── test/                              # Local testing
│   ├── mock-mcp-server.py             # Standalone mock MCP server
│   ├── praxis-test-config.yaml        # Local Praxis config
│   ├── simulate-traffic.sh            # Traffic generator
│   └── TEST_INSTRUCTIONS.md           # Step-by-step local test guide
│
└── upstream-pr/                       # PR preparation for praxis-proxy/ai
    ├── PR_DESCRIPTION.md              # Ready-to-paste PR description
    ├── GITHUB_ISSUE.md                # Ready-to-paste GitHub issue
    ├── REJECTION_METRIC_PATCH.md      # Detailed rejection code path documentation
    ├── MOD_RS_PATCHES.md              # All mod.rs patches documented
    └── push-to-fork.sh               # Script to push to your fork
```

## Quick Start — Deploy on OpenShift

**Prerequisites:** `oc` CLI logged into an OCP 4.x cluster, cluster-admin or namespace-admin on your project.

### Option A: Full Deploy (Recommended)

```bash
git clone https://github.com/redhat-telco-guy/praxis-mcp-observability.git
cd praxis-mcp-observability

# Step 1: Build the Praxis image on-cluster (compiles Rust, ~12-15 min)
bash build/build-on-ocp.sh

# Step 2: Deploy everything (mock servers, Praxis, dashboard, ServiceMonitor)
bash deploy/deploy-all.sh
```

Step 1 builds the container image entirely on the OCP cluster (no local Rust needed). Step 2 deploys the full stack. When done, it prints the dashboard URL.

### Option B: Step-by-Step

```bash
# 1. Create project
oc new-project praxis-mcp-test

# 2. Deploy mock MCP servers
oc apply -f deploy/mock-servers.yaml

# 3. Build Praxis with metrics patches
oc new-build --name=praxis-ai-mcp-metrics \
  --strategy=docker \
  --dockerfile="$(cat build/Containerfile)" \
  --to=praxis-ai:mcp-metrics

oc start-build praxis-ai-mcp-metrics \
  --from-dir=. --follow

# 4. Deploy Praxis + ServiceMonitor
# (see deploy/deploy-all.sh for the full manifest set)

# 5. Deploy dashboard
oc create configmap dashboard-html --from-file=dashboard.html=dashboard/dashboard.html
# (see deploy/deploy-all.sh for httpd deployment)
```

### Verify Metrics Are Flowing

```bash
# Quick smoke test
PRAXIS_URL=$(oc get route praxis-ai -o jsonpath='{.spec.host}')

# Send a valid request
curl -sk -X POST "https://${PRAXIS_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# Check metrics
curl -sk "https://${PRAXIS_URL}:9902/metrics" | grep praxis_mcp
```

Or use the 8-layer diagnostic script:

```bash
bash diagnostics/check-metrics.sh
```

### Verify in OCP Console (Prometheus)

1. Open OCP Console → **Observe** → **Metrics**
2. Paste: `praxis_mcp_requests_total`
3. Click **Run Queries**
4. You should see data points for each MCP method

**Important:** User Workload Monitoring must be enabled:
```bash
oc -n openshift-monitoring create configmap cluster-monitoring-config \
  --from-literal=config.yaml='enableUserWorkload: true' \
  --dry-run=client -o yaml | oc apply -f -
```

## OCP-Specific Notes

### allow_private_upstreams

On OpenShift, Kubernetes Service ClusterIPs (e.g., 172.30.x.x) are in the private IP range. Praxis blocks connections to private IPs by default. You must set:

```yaml
insecure_options:
  allow_private_upstreams: true
```

Without this, every upstream connection fails with: `upstream address resolved to private/reserved IP address`.

### ServiceMonitor Filtering

The included ServiceMonitor uses `metricRelabelings` to keep only MCP metrics in Prometheus, reducing storage:

```yaml
metricRelabelings:
  - action: keep
    regex: praxis_mcp_.*
    sourceLabels: [__name__]
```

Remove this filter if you also want the standard Praxis HTTP/filter metrics.

## The Code — What Gets Contributed Upstream

### `src/metrics.rs` (New File — 372 lines)

This is the core contribution. It defines:

- 4 metric constants (`METRIC_MCP_REQUESTS_TOTAL`, etc.)
- 2 metadata keys for cross-phase state (`META_MCP_REQUEST_START_NS`, `META_MCP_TOOL_NAME`)
- Cardinality bounding via `ArcSwap<HashSet>` — tool name labels are capped at 512 distinct values, overflow maps to `"other"`
- 3 recording functions: `record_mcp_request()`, `record_tool_call_completed()`, `record_filter_rejection()`
- 5 unit tests including a concurrent admission test

The code follows the exact patterns from Praxis's existing `llm_metrics.rs`:
- Same `counter!` / `histogram!` macros from the `metrics` crate
- Same `describe_histogram!` for units
- Same `Once`-guarded initialization
- Same test style using `DebuggingRecorder`

### `src/patch-mod-rs.py` (Build-Time Patcher)

Since this is a demo/proof-of-concept, we don't fork the entire Praxis repo. Instead, the container build clones upstream Praxis and applies patches at build time:

- **Patch 1:** Add `pub(crate) mod metrics;` declaration
- **Patch 2:** Add `SystemTime` import
- **Patch 3:** Add metrics function imports
- **Patch 4:** Record request metrics after JSON-RPC parsing
- **Patch 5:** Record `invalid_params` rejection
- **Patch 6:** Record `header_mismatch` rejection
- **Patch 6b:** Record `missing_header` rejection
- **Patch 6c:** Record `invalid_jsonrpc` rejection
- **Patch 7:** Add `on_response` method for latency measurement

For the actual upstream PR, these patches become direct code changes to `filters/src/agentic/mcp/mod.rs`.

## Interactive Dashboard

The dashboard (`dashboard/dashboard.html`) is a self-contained HTML file with 5 tabs:

| Tab | What It Shows |
|-----|---------------|
| **Metrics** | Live counters for all 4 MCP metrics, auto-refreshing every 5 seconds |
| **Test Lab** | Buttons to send traffic to each mock server + a rejection trigger |
| **Architecture** | Animated SVG showing data/control/rejection flows through the proxy |
| **Prometheus** | Step-by-step walkthrough for viewing metrics in OCP Console |
| **Gap Analysis** | Comparison: 71 existing Praxis metrics → 4 new MCP metrics added |

No external CDN dependencies — everything is inline.

## PromQL Examples

```promql
# Request rate by MCP method (per second, 5m window)
rate(praxis_mcp_requests_total[5m])

# Top 5 most-called tools
topk(5, sum by (tool) (praxis_mcp_tool_calls_total))

# Tool error rate
sum by (tool) (rate(praxis_mcp_tool_calls_total{status="error"}[5m]))
/ sum by (tool) (rate(praxis_mcp_tool_calls_total[5m]))

# P95 tool call latency
histogram_quantile(0.95, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))

# Rejection rate by reason
sum by (reason) (rate(praxis_mcp_filter_rejections_total[5m]))
```

## Contributing Upstream

This project includes everything needed to open a PR against `praxis-proxy/ai`:

1. **File the issue** — copy `upstream-pr/GITHUB_ISSUE.md` into a new issue at [praxis-proxy/ai](https://github.com/praxis-proxy/ai/issues)
2. **Fork praxis-proxy/ai** to your GitHub account
3. **Run the push script:**
   ```bash
   # Edit upstream-pr/push-to-fork.sh with your fork URL
   bash upstream-pr/push-to-fork.sh
   ```
4. **Open the PR** — copy `upstream-pr/PR_DESCRIPTION.md` as the PR body

The PR adds exactly 2 files changed:
- `filters/src/agentic/mcp/metrics.rs` (new file)
- `filters/src/agentic/mcp/mod.rs` (integration patches)

## Testing Locally

See `test/TEST_INSTRUCTIONS.md` for full local testing without OCP. Quick version:

```bash
# Start mock server
python3 test/mock-mcp-server.py &

# Build Praxis with metrics
cd /path/to/praxis-proxy-ai
cp src/metrics.rs filters/src/agentic/mcp/metrics.rs
python3 src/patch-mod-rs.py
cargo build --release

# Run with test config
./target/release/praxis-ai -c test/praxis-test-config.yaml

# Generate traffic
bash test/simulate-traffic.sh
```

## Tested On

- OpenShift 4.22.22, BareMetal, 5 nodes
- Praxis upstream `main` branch (as of November 2026)
- Rust 1.x (whatever upstream Praxis uses)
- Dashboard verified on Chrome, Firefox, Safari

## License

Apache License 2.0 — same as Praxis.

## Author

**Puneet Marhatha** ([@redhat-telco-guy](https://github.com/redhat-telco-guy))
Red Hat — pmarhath@redhat.com
