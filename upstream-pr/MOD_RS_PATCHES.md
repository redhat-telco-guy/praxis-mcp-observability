# Patches to `filters/src/agentic/mcp/mod.rs`

These are the exact changes needed to integrate MCP metrics into the existing
MCP filter. Each patch is applied by `src/patch-mod-rs.py` during the build.

## Patch 1: Add the metrics module declaration

**After:** `mod broker;`
**Add:**
```rust
pub(crate) mod metrics;
```

## Patch 2: Add `std::time::SystemTime` to imports

**After:** `use std::borrow::Cow;`
**Replace with:**
```rust
use std::{borrow::Cow, time::SystemTime};
```

## Patch 3: Add `metrics` import

**After the existing `use self::{...}` block, add:**
```rust
use self::metrics::{
    record_mcp_request, record_filter_rejection, record_tool_call_completed,
    McpMetricsState,
};
use self::envelope::McpMethod;
```

## Patch 4: Record request metrics in `on_request_body`

**After the `trace!` call, add:**
```rust
        // ── MCP metrics (request phase) ──
        let method_str = mcp_envelope.method.as_str();
        let pv = mcp_envelope
            .protocol_version
            .as_deref()
            .unwrap_or("unknown");
        record_mcp_request(method_str, pv);

        // For tools/call, store per-instance metrics state for the response phase.
        // Uses filter_state (keyed by current_filter_id) so two MCP filter
        // instances in the same pipeline do not overwrite each other.
        if matches!(mcp_envelope.method, McpMethod::ToolsCall) {
            let epoch_ns = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            let tool_name = mcp_envelope
                .name
                .as_deref()
                .unwrap_or("unknown")
                .to_owned();
            ctx.insert_filter_state(McpMetricsState {
                start_ns: epoch_ns,
                tool_name,
            });
        }
```

## Patch 5: Record rejection for `invalid_params`

**Wrap `Some(mcp_invalid_params_rejection(...))` match arms in a block:**
```rust
=> {
    record_filter_rejection(mcp.method.as_str(), "invalid_params");
    Some(mcp_invalid_params_rejection(...))
}
```

## Patch 6: Record rejection for `header_mismatch` and `missing_header`

**Before `Err(mcp_header_mismatch_rejection(...))` returns:**
```rust
record_filter_rejection("unknown", "header_mismatch");
```

**Before `Err(FilterAction::Reject(Rejection::status(400)))` for missing headers:**
```rust
record_filter_rejection("unknown", "missing_header");
```

## Patch 6c: Record rejection for `invalid_jsonrpc`

**Replace `Err(action) => return action,` with a block that only counts actual rejections:**
```rust
Err(action) => {
    if matches!(&action, Ok(FilterAction::Reject(_)) | Err(_)) {
        record_filter_rejection("unknown", "invalid_jsonrpc");
    }
    return action;
},
```

## Patch 7: Add response phase for duration + transport status metrics

**Add `on_response` to the `HttpFilter for McpFilter` impl block:**

```rust
    async fn on_response(
        &self,
        ctx: &mut HttpFilterContext<'_>,
    ) -> Result<FilterAction, FilterError> {
        // Only record duration for tool calls that stored metrics state.
        // Uses filter_state (per-instance) so two MCP filters in the same
        // pipeline each track their own tool call independently.
        if let Some(state) = ctx.get_filter_state::<McpMetricsState>() {
            let now_ns = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            let elapsed = std::time::Duration::from_nanos(
                now_ns.saturating_sub(state.start_ns),
            );
            let duration_seconds = elapsed.as_secs_f64();

            let tool = &state.tool_name;
            let cluster = ctx
                .cluster_name()
                .unwrap_or("unknown");

            // transport_status reflects HTTP status only. JSON-RPC
            // application errors inside HTTP 200 are recorded as "ok".
            let is_error = ctx
                .response_header
                .as_ref()
                .map_or(false, |r| r.status.as_u16() >= 400);
            let transport_status = if is_error { "error" } else { "ok" };

            record_tool_call_completed(tool, cluster, transport_status, duration_seconds);
        }
        Ok(FilterAction::Continue)
    }
```
