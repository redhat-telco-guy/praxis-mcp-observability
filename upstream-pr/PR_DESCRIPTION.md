# feat(mcp): add per-tool Prometheus metrics for MCP traffic

Closes #XXXX

## What this does

Adds four Prometheus metrics to the `mcp` filter, bringing Praxis to parity with Kong AI Gateway's MCP-specific observability. The MCP filter already extracts tool name, method, session, and protocol version from every request — this PR records that metadata as Prometheus metrics.

## New metrics

| Metric | Type | Labels | Answers |
|--------|------|--------|---------|
| `praxis_mcp_requests_total` | Counter | `method`, `protocol_version` | How many MCP requests by method? |
| `praxis_mcp_tool_calls_total` | Counter | `tool`, `cluster`, `status` | Which tools are called most? Which are failing? |
| `praxis_mcp_tool_call_duration_seconds` | Histogram | `tool`, `cluster` | How fast is each tool's upstream? |
| `praxis_mcp_filter_rejections_total` | Counter | `method`, `reason` | Are clients sending malformed requests? |

## Files changed

| File | Status | What |
|------|--------|------|
| `filters/src/agentic/mcp/metrics.rs` | **New** | Metric constants, recording helpers, tool-name cardinality bounding (MAX_TOOL_LABELS=512), unit tests |
| `filters/src/agentic/mcp/mod.rs` | **Modified** | Record request counts in `on_request_body`, store start time for tools/call, add `on_response` for duration + status, record rejections |

## Design decisions

**Cardinality bounding.** Tool names use the same `ArcSwap<HashSet>` admission pattern as `llm_metrics.rs::admit_model()` — lock-free reads, serialized first-time admission, hard cap at 512, overflow → `"other"`. All other labels are closed vocabularies.

**Cross-phase timing.** `on_request_body` stores `SystemTime::now()` as nanos-since-epoch in metadata. `on_response` reads it back and computes the delta. This avoids per-request heap allocation — metadata values are strings, and the `u128` → string → `u128` round-trip is ~20ns.

**Rejection metrics.** Each `FilterAction::Reject` path in the filter now calls `record_filter_rejection()` before returning. The `reason` label is a closed set of 3 values: `invalid_params`, `header_mismatch`, `missing_header`.

## Performance

- Counter increment: lock-free atomic (~10-20ns)
- Histogram record: mutex-guarded bucket update (~50-100ns)
- Cardinality admission: lock-free read on hot path; mutex only on first encounter of a new tool name
- Total overhead: < 200ns per request, negligible vs MCP round-trip latency

## No new dependencies

Uses existing `metrics`, `arc_swap`, `metrics_util` (dev) crates already in the workspace.

## Testing

```bash
# Unit tests
cargo test -p praxis-ai-filters -- mcp::metrics

# Integration: start Praxis with MCP filter, make tool calls
curl -s http://localhost:9090/metrics | grep praxis_mcp

# Expected:
# praxis_mcp_requests_total{method="tools/call",protocol_version="2025-11-25"} 5
# praxis_mcp_tool_calls_total{cluster="mcp-github",status="ok",tool="search_repos"} 3
# praxis_mcp_tool_call_duration_seconds_bucket{cluster="mcp-github",tool="search_repos",le="0.25"} 2
```

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>
