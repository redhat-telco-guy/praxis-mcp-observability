# feat(mcp): add per-tool Prometheus metrics for MCP traffic

## Problem

The MCP filter (`filters/src/agentic/mcp/`) extracts rich protocol metadata — method, tool name, session ID, protocol version — and promotes it to headers and filter results for routing. However, none of this metadata is recorded as Prometheus metrics. Operators running Praxis with MCP traffic have no visibility into:

- Which tools are being called and how often
- Per-tool upstream latency
- Per-tool error rates
- MCP method mix (tools/call vs tools/list vs initialize)
- Filter rejection rates

This is a notable gap versus competing gateways: Kong AI Gateway 2.2 ships MCP-specific OTel metrics (per-tool call counts, latency histograms, error rates), and Portkey logs every MCP tool invocation with latency and status.

Meanwhile, Praxis already has mature metrics for LLM inference (9 metrics in `llm_metrics.rs`) and intelligent routing (6 metrics in `routing/metrics.rs`). The MCP filter is the only major AI-traffic filter with zero Prometheus instrumentation.

## Proposed solution

Add four Prometheus metrics to the MCP filter, following the existing `llm_metrics.rs` pattern:

| Metric | Type | Labels | What it answers |
|--------|------|--------|-----------------|
| `praxis_mcp_requests_total` | Counter | `method`, `protocol_version` | MCP request volumes by method |
| `praxis_mcp_tool_calls_total` | Counter | `tool`, `cluster`, `status` | Per-tool call counts with success/failure |
| `praxis_mcp_tool_call_duration_seconds` | Histogram | `tool`, `cluster` | Upstream round-trip time per tool |
| `praxis_mcp_filter_rejections_total` | Counter | `method`, `reason` | Filter-level rejections |

### Label cardinality

All labels are from closed vocabularies or bounded configuration. Tool names are additionally capped at 512 distinct values per process lifetime (matching the `MAX_MODEL_LABELS` pattern in `llm_metrics`), with overflow mapped to `"other"`.

### Implementation sketch

- New file: `filters/src/agentic/mcp/metrics.rs` — metric constants, recording helpers, tool-name cardinality bounding
- Modified: `filters/src/agentic/mcp/mod.rs` — record request counts in `on_request_body`, record tool call duration/status in `on_response`

### No new dependencies

Uses existing `metrics`, `arc_swap` crates already in the workspace.

## Example PromQL queries

```promql
# Per-tool error rate
rate(praxis_mcp_tool_calls_total{status="error"}[5m])
  / rate(praxis_mcp_tool_calls_total[5m]) > 0.05

# p99 tool call latency
histogram_quantile(0.99, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))

# Top tools by call rate
topk(10, rate(praxis_mcp_tool_calls_total[5m]))

# MCP method mix
rate(praxis_mcp_requests_total[5m])
```

## Checklist

- [ ] No new dependencies
- [ ] Label cardinality bounded
- [ ] Follows existing `llm_metrics.rs` pattern
- [ ] Unit tests included
- [ ] Zero overhead when no MCP traffic flows (no allocations until first record)
