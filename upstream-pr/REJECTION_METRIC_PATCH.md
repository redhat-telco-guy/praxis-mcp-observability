# Patch: Wire `praxis_mcp_filter_rejections_total` into rejection code paths

## Problem

The `record_filter_rejection()` function exists in `metrics.rs` but is never
called from `mod.rs`. The MCP filter rejects malformed requests (returns 400
or JSON-RPC error) without recording the rejection metric. Three of four MCP
metrics work; this patch fixes the fourth.

## Where rejections happen in `filters/src/agentic/mcp/mod.rs`

There are **4 rejection points** in the upstream code:

| # | Function | Condition | Rejection type |
|---|----------|-----------|----------------|
| 1 | `reject_missing_required_selector` | tools/call without a tool name | `mcp_invalid_params_rejection` (JSON-RPC -32602) |
| 2 | `validate_mcp_headers` | Mcp-Name header present but method has no name | `mcp_header_mismatch_rejection` (JSON-RPC -32001) |
| 3 | `validate_single_header` | Header value doesn't match body OR invalid UTF-8 | `mcp_header_mismatch_rejection` (JSON-RPC -32001) |
| 4 | `validate_single_header` | Header missing when `missing: reject` configured | `FilterAction::Reject(Rejection::status(400))` |

Plus: the JSON-RPC body parser itself can reject (returns `Err(action)` in
`on_request_body`) — but that's in shared code, not MCP-specific.

## Exact patches (old → new)

### Patch A: Add `record_filter_rejection` to imports

In the existing `use self::{...}` block at the top of `mod.rs`, the metrics
module and its functions need to be imported. If `metrics` module is already
declared (`pub(crate) mod metrics;`), add this import:

```rust
// Add after the existing `use self::{ config::..., envelope::... }` block:
use self::metrics::record_filter_rejection;
```

### Patch B: Rejection point 1 — `reject_missing_required_selector`

**File:** `filters/src/agentic/mcp/mod.rs`
**Function:** `reject_missing_required_selector`

```rust
// BEFORE (upstream):
fn reject_missing_required_selector(
    mcp: &McpEnvelope,
    envelope: &praxis_filter::builtins::http::payload_processing::json_rpc::envelope::JsonRpcEnvelope,
    config: &McpConfig,
) -> Option<FilterAction> {
    let requires = mcp.method.requires_name() || mcp.method.requires_uri();
    if requires && mcp.name.is_none() {
        match config.on_invalid {
            OnInvalidBehavior::Reject | OnInvalidBehavior::Error => Some(mcp_invalid_params_rejection(envelope)),
            OnInvalidBehavior::Continue => Some(FilterAction::Continue),
        }
    } else {
        None
    }
}

// AFTER (with rejection metric):
fn reject_missing_required_selector(
    mcp: &McpEnvelope,
    envelope: &praxis_filter::builtins::http::payload_processing::json_rpc::envelope::JsonRpcEnvelope,
    config: &McpConfig,
) -> Option<FilterAction> {
    let requires = mcp.method.requires_name() || mcp.method.requires_uri();
    if requires && mcp.name.is_none() {
        match config.on_invalid {
            OnInvalidBehavior::Reject | OnInvalidBehavior::Error => {
                record_filter_rejection(mcp.method.as_str(), "invalid_params");
                Some(mcp_invalid_params_rejection(envelope))
            },
            OnInvalidBehavior::Continue => Some(FilterAction::Continue),
        }
    } else {
        None
    }
}
```

### Patch C: Rejection point 2 — `validate_mcp_headers` (name mismatch)

**Function:** `validate_mcp_headers`

```rust
// BEFORE:
    } else if ctx.request.headers.get("mcp-name").is_some() {
        match config.header_validation.mismatch {
            MismatchBehavior::Reject => {
                warn!("client sent Mcp-Name header but body method has no name");
                return Err(mcp_header_mismatch_rejection(envelope));
            },
            MismatchBehavior::Ignore => {},
        }
    }

// AFTER:
    } else if ctx.request.headers.get("mcp-name").is_some() {
        match config.header_validation.mismatch {
            MismatchBehavior::Reject => {
                warn!("client sent Mcp-Name header but body method has no name");
                record_filter_rejection(mcp.method.as_str(), "header_mismatch");
                return Err(mcp_header_mismatch_rejection(envelope));
            },
            MismatchBehavior::Ignore => {},
        }
    }
```

### Patch D: Rejection point 3 — `validate_single_header` (value mismatch / bad UTF-8)

**Function:** `validate_single_header`

There are **three** `Reject` branches in this function. Add `record_filter_rejection`
before each rejection return:

```rust
// BEFORE (invalid UTF-8):
                MismatchBehavior::Reject => {
                    warn!(header_name = header_name, "MCP header contains invalid UTF-8");
                    return Err(mcp_header_mismatch_rejection(envelope));
                },

// AFTER:
                MismatchBehavior::Reject => {
                    warn!(header_name = header_name, "MCP header contains invalid UTF-8");
                    record_filter_rejection("unknown", "header_mismatch");
                    return Err(mcp_header_mismatch_rejection(envelope));
                },
```

```rust
// BEFORE (value mismatch):
                MismatchBehavior::Reject => {
                    warn!(
                        header_name = header_name,
                        header_value = header_value,
                        body_value = body_value,
                        "MCP header/body mismatch"
                    );
                    return Err(mcp_header_mismatch_rejection(envelope));
                },

// AFTER:
                MismatchBehavior::Reject => {
                    warn!(
                        header_name = header_name,
                        header_value = header_value,
                        body_value = body_value,
                        "MCP header/body mismatch"
                    );
                    record_filter_rejection("unknown", "header_mismatch");
                    return Err(mcp_header_mismatch_rejection(envelope));
                },
```

### Patch E: Rejection point 4 — `validate_single_header` (missing header)

```rust
// BEFORE:
            MissingHeaderBehavior::Reject => {
                return Err(FilterAction::Reject(Rejection::status(400)));
            },

// AFTER:
            MissingHeaderBehavior::Reject => {
                record_filter_rejection("unknown", "missing_header");
                return Err(FilterAction::Reject(Rejection::status(400)));
            },
```

### Patch F: Rejection from JSON-RPC parser (body-level rejection)

In `on_request_body`, the JSON-RPC parser can also reject. This is the
`Err(action) => return action` branch. Add a metric call here too:

```rust
// BEFORE:
            Ok(None) => return Ok(FilterAction::Continue),
            Err(action) => return action,

// AFTER:
            Ok(None) => return Ok(FilterAction::Continue),
            Err(action) => {
                record_filter_rejection("unknown", "invalid_jsonrpc");
                return action;
            },
```

This catches malformed JSON, non-JSON-RPC bodies, batch requests, and
oversized bodies — the most common rejection scenario in practice
(and the one triggered by the dashboard's "Send Malformed Request" button).

## Summary

After applying all 6 patches (A–F), every rejection path in the MCP filter
increments `praxis_mcp_filter_rejections_total` with a `reason` label from
this closed set:

| reason | trigger |
|--------|---------|
| `invalid_params` | tools/call without tool name |
| `header_mismatch` | MCP header doesn't match body |
| `missing_header` | required header absent |
| `invalid_jsonrpc` | malformed JSON-RPC body |

## How to apply

These patches go into your fork of `praxis-proxy/ai` at:
`filters/src/agentic/mcp/mod.rs`

The `metrics.rs` file already has `record_filter_rejection()` defined —
no changes needed there. You just need to call it from the rejection points.
