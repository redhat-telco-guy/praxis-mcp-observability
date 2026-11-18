# Reviewer Responses for PR #2030

## Reply to Comment 1 — filter_state

> Post this as a reply to tsisodia10's comment about shared metadata keys

---

Good catch — fixed. I replaced the shared `filter_metadata` string keys (`META_MCP_REQUEST_START_NS`, `META_MCP_TOOL_NAME`) with a typed `McpMetricsState` struct stored in `filter_state`:

```rust
pub(crate) struct McpMetricsState {
    pub start_ns: u64,
    pub tool_name: String,
}
```

Request phase stores it via `ctx.insert_filter_state(McpMetricsState { ... })`, response phase retrieves it via `ctx.get_filter_state::<McpMetricsState>()`. Since `filter_state` is keyed by `current_filter_id`, two MCP filter instances in the same pipeline each track their own tool call independently — no shared keys, no overwrites.

Verified on OCP — tool call counts and latency are recording correctly, which proves the `filter_state` round-trip works (both metrics fire only inside the `if let Some(state) = ctx.get_filter_state()` block).

---

## Reply to Comment 2 — transport_status

> Post this as a reply to tsisodia10's comment about status label semantics

---

Good point — fixed. Renamed the label from `status` to `transport_status` to make clear it reflects HTTP transport outcome only (`"ok"` for 2xx/3xx, `"error"` for 4xx/5xx).

A tool returning a JSON-RPC `{"error": ...}` inside HTTP 200 is intentionally recorded as `transport_status="ok"` — detecting application-level errors would require response body parsing, which is a separate concern and can be added in a follow-up.

The label name now makes the limitation explicit so dashboard builders don't treat it as the tool result.

Verified on the live cluster:

```
praxis_mcp_tool_calls_total{tool="get_weather",cluster="weather-mcp",transport_status="ok"} 3
praxis_mcp_tool_calls_total{tool="translate",cluster="translator-mcp",transport_status="ok"} 2
praxis_mcp_tool_calls_total{tool="add",cluster="calculator-mcp",transport_status="ok"} 2
```
