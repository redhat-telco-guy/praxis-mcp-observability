# Patches to `filters/src/agentic/mcp/mod.rs`

These are the exact changes needed to integrate MCP metrics into the existing
MCP filter. Each patch is described as an old → new replacement.

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
    record_mcp_request, record_filter_rejection,
    META_MCP_REQUEST_START_NS,
};
```

## Patch 4: Add `request_start` field to `McpFilter`

**In the `McpFilter` struct, after `max_body_bytes: usize,`:**

No change needed — timing state is stored in `HttpFilterContext` metadata,
not in the filter struct (the filter is shared across requests).

## Patch 5: Record request metrics in `on_request_body`

**In `on_request_body`, after the `trace!` call and before `Ok(FilterAction::Release)`, add:**

```rust
        // ── MCP metrics (request phase) ──
        let method_str = mcp_envelope.method.as_str();
        let pv = mcp_envelope
            .protocol_version
            .as_deref()
            .unwrap_or("unknown");
        record_mcp_request(method_str, pv);

        // For tools/call, record the start time so the response phase can
        // compute duration. Stored as nanos-since-epoch string in metadata
        // (metadata values are strings; Instant is not serializable).
        if matches!(mcp_envelope.method, envelope::McpMethod::ToolsCall) {
            let start = Instant::now();
            // Store as pointer-sized integer for zero-alloc round-trip.
            ctx.set_metadata(
                META_MCP_REQUEST_START_NS,
                format!("{}", start.elapsed().as_nanos()),
            );
            // Actually we need the instant itself — store epoch nanos.
            let epoch_ns = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            ctx.set_metadata(META_MCP_REQUEST_START_NS, epoch_ns.to_string());
        }
```

## Patch 6: Record rejection metrics

**In `reject_missing_required_selector`, before each `Some(mcp_invalid_params_rejection(...))` return, add:**

```rust
                record_filter_rejection(mcp.method.as_str(), "invalid_params");
```

**In `validate_mcp_headers`, before each `Err(mcp_header_mismatch_rejection(...))` return, add:**

```rust
                record_filter_rejection("unknown", "header_mismatch");
```

**In `validate_single_header`, before the `Err(FilterAction::Reject(Rejection::status(400)))` return for missing headers, add:**

```rust
                record_filter_rejection("unknown", "missing_header");
```

## Patch 7: Add response phase for duration + status metrics

**Add `on_response` implementation to the `HttpFilter for McpFilter` impl block:**

```rust
    async fn on_response(
        &self,
        ctx: &mut HttpFilterContext<'_>,
        _upstream_response: &http::Response<()>,
    ) -> Result<FilterAction, FilterError> {
        // Only record duration for tool calls that stored a start time.
        if let Some(start_ns_str) = ctx.get_metadata(metrics::META_MCP_REQUEST_START_NS) {
            if let Ok(start_ns) = start_ns_str.parse::<u128>() {
                let now_ns = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                let duration_seconds = (now_ns.saturating_sub(start_ns)) as f64 / 1_000_000_000.0;

                let tool = ctx
                    .get_metadata(metrics::META_MCP_TOOL_NAME)
                    .unwrap_or("unknown");
                let cluster = ctx
                    .cluster_name()
                    .unwrap_or("unknown");
                let status_code = ctx
                    .response_header
                    .as_ref()
                    .map_or(false, |r| r.status.as_u16() >= 400);
                let status = if status_code { "error" } else { "ok" };

                metrics::record_tool_call_completed(tool, cluster, status, duration_seconds);
            }
        }
        Ok(FilterAction::Continue)
    }
```

**Note:** The exact `on_response` signature depends on the `HttpFilter` trait definition in `praxis_filter`. The above matches the pattern from other Praxis filters. If the trait uses a different signature (e.g., separate `status_code` parameter), adjust accordingly.
