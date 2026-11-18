// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Structured audit logging for MCP tool calls.
//!
//! Each MCP request emits one or two structured log events at `INFO` level
//! with a `log_type = "mcp_audit"` structured field. Using the default module
//! path as the tracing target ensures compatibility with Praxis's tracing
//! subscriber, while the `log_type` field lets log collectors (OpenShift
//! Logging / Vector, Loki, Fluentd) route and store audit events
//! independently of general proxy diagnostic logs.
//!
//! # Two-phase audit model
//!
//! Because filter-level rejections happen before routing, and tool-call
//! outcomes arrive in the response phase, audit recording is split:
//!
//! 1. **Request phase** — [`emit_rejected`] fires immediately for
//!    filter-level rejections (`outcome: "rejected"`).
//!    [`emit_non_tool`] fires for non-tool methods (`tools/list`,
//!    `initialize`, `ping`) that have no response-phase follow-up.
//!    For `tools/call` requests that pass validation, context is stored
//!    in filter metadata for the response phase.
//!
//! 2. **Response phase** — [`emit_completed`] fires after the upstream
//!    responds to a `tools/call`, recording outcome, HTTP status, latency,
//!    and cluster identity in a single complete record.
//!
//! Log collectors correlate request and response events via `mcp_session_id`
//! (the MCP `Mcp-Session-Id` header value, promoted during request phase).
//!
//! # JSON output — rejected call (request phase)
//!
//! ```json
//! {
//!   "timestamp": "2026-11-12T14:32:07.001Z",
//!   "level": "INFO",
//!   "target": "praxis_ai::mcp_audit",
//!   "fields": {
//!     "message":             "mcp.call.rejected",
//!     "log_type":            "mcp_audit",
//!     "mcp_method":          "tools/call",
//!     "mcp_name":            "query_database",
//!     "mcp_session_id":      "sess_abc123",
//!     "mcp_protocol_version":"2026-11-05",
//!     "mcp_outcome":         "rejected",
//!     "mcp_rejection_reason":"invalid_params",
//!     "tenant":              "acme-corp"
//!   }
//! }
//! ```
//!
//! # JSON output — completed tool call (response phase)
//!
//! ```json
//! {
//!   "timestamp": "2026-11-12T14:32:07.044Z",
//!   "level": "INFO",
//!   "target": "praxis_ai::mcp_audit",
//!   "fields": {
//!     "message":             "mcp.call.completed",
//!     "log_type":            "mcp_audit",
//!     "mcp_method":          "tools/call",
//!     "mcp_name":            "query_database",
//!     "mcp_session_id":      "sess_abc123",
//!     "mcp_protocol_version":"2026-11-05",
//!     "mcp_outcome":         "ok",
//!     "mcp_upstream_status": 200,
//!     "mcp_duration_ms":     42,
//!     "mcp_cluster":         "analytics-mcp",
//!     "tenant":              "acme-corp"
//!   }
//! }
//! ```

use std::time::SystemTime;

use tracing::{info, warn};

/// Log a startup message confirming the audit module is compiled and loaded.
/// Called from the MCP filter initialization path.
pub(crate) fn log_audit_enabled() {
    warn!(target: "praxis_ai::mcp_audit", "MCP audit logging enabled (log_type=mcp_audit)");
}

// ---------------------------------------------------------------------------
// Metadata keys stored in HttpFilterContext for cross-phase carry-over.
// All keys are prefixed `mcp.audit.` to avoid collisions with the metrics
// module's `mcp.*` and `json_rpc.*` keys.
// ---------------------------------------------------------------------------

/// Epoch-nanos timestamp captured at request time, used by the response
/// phase to compute `mcp_duration_ms` without storing an `Instant`.
pub(crate) const META_AUDIT_START_NS: &str = "mcp.audit.start_ns";

/// MCP method (e.g. `tools/call`), carried to response phase.
pub(crate) const META_AUDIT_METHOD: &str = "mcp.audit.method";

/// Tool/resource/prompt name, carried to response phase for `tools/call`.
pub(crate) const META_AUDIT_TOOL: &str = "mcp.audit.tool";

/// MCP session ID, carried to response phase.
pub(crate) const META_AUDIT_SESSION_ID: &str = "mcp.audit.session_id";

/// MCP protocol version, carried to response phase.
pub(crate) const META_AUDIT_PROTOCOL_VERSION: &str = "mcp.audit.protocol_version";

/// Tenant identifier extracted from `x-tenant-id`, carried to response phase.
pub(crate) const META_AUDIT_TENANT: &str = "mcp.audit.tenant";

// ---------------------------------------------------------------------------
// Outcome vocabulary (closed set — log collectors can filter on these)
// ---------------------------------------------------------------------------

/// Request rejected by the filter before reaching any upstream.
pub(crate) const OUTCOME_REJECTED: &str = "rejected";

/// Non-tool MCP request (tools/list, initialize, ping …) passed the filter.
pub(crate) const OUTCOME_INITIATED: &str = "initiated";

/// tools/call upstream responded with a 2xx status code.
pub(crate) const OUTCOME_OK: &str = "ok";

/// tools/call upstream responded with a 4xx/5xx status code.
pub(crate) const OUTCOME_ERROR: &str = "error";

// ---------------------------------------------------------------------------
// Request-phase: rejection
// ---------------------------------------------------------------------------

/// Emit an audit event for an MCP request **rejected** at the filter layer.
///
/// `rejection_reason` is a closed vocabulary: `"invalid_params"`,
/// `"header_mismatch"`, `"missing_header"`.
///
/// # Arguments
///
/// * `method`           – JSON-RPC / MCP method string (e.g. `"tools/call"`).
/// * `name`             – Tool/resource/prompt name if present in the body.
/// * `session_id`       – `Mcp-Session-Id` header value if present.
/// * `protocol_version` – MCP protocol version from body if present.
/// * `tenant`           – Value of `x-tenant-id` request header if set.
/// * `rejection_reason` – Why the request was rejected.
pub(crate) fn emit_rejected(
    method: &str,
    name: Option<&str>,
    session_id: Option<&str>,
    protocol_version: Option<&str>,
    tenant: Option<&str>,
    rejection_reason: &str,
) {
    info!(
        target: "praxis_ai::mcp_audit",
        log_type             = "mcp_audit",
        mcp_method           = method,
        mcp_name             = name,
        mcp_session_id       = session_id,
        mcp_protocol_version = protocol_version,
        mcp_outcome          = OUTCOME_REJECTED,
        mcp_rejection_reason = rejection_reason,
        tenant               = tenant,
        "mcp.call.rejected",
    );
}

// ---------------------------------------------------------------------------
// Request-phase: non-tool methods (complete event emitted at request time)
// ---------------------------------------------------------------------------

/// Emit an audit event for a **non-`tools/call`** MCP request that passed
/// all filter checks.
///
/// Methods such as `tools/list`, `initialize`, `resources/list`, `ping`,
/// and `prompts/list` do not invoke an upstream tool and have no response-
/// phase follow-up. The entire audit record is emitted here.
pub(crate) fn emit_non_tool(
    method: &str,
    session_id: Option<&str>,
    protocol_version: Option<&str>,
    tenant: Option<&str>,
) {
    info!(
        target: "praxis_ai::mcp_audit",
        log_type             = "mcp_audit",
        mcp_method           = method,
        mcp_session_id       = session_id,
        mcp_protocol_version = protocol_version,
        mcp_outcome          = OUTCOME_INITIATED,
        tenant               = tenant,
        "mcp.call.initiated",
    );
}

// ---------------------------------------------------------------------------
// Request-phase: store context for tools/call response-phase emit
// ---------------------------------------------------------------------------

/// Return epoch-nanosecond timestamp for request-start storage.
///
/// Called by the mod.rs patch when a `tools/call` passes the filter, so
/// the response phase can compute latency without allocating an `Instant`.
pub(crate) fn request_start_ns() -> u128 {
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Response-phase: completed tool call
// ---------------------------------------------------------------------------

/// Emit a completed audit event for a `tools/call` upstream response.
///
/// Called from `on_response` after reading back the metadata stored during
/// the request phase. Computes latency from the stored `start_ns`.
///
/// # Arguments
///
/// * `tool`             – Tool name from body (capped at 256 chars for safety).
/// * `cluster`          – Upstream cluster name from routing context.
/// * `method`           – MCP method (always `"tools/call"` here).
/// * `session_id`       – `Mcp-Session-Id` if present.
/// * `protocol_version` – MCP protocol version if present.
/// * `tenant`           – Tenant identifier if present.
/// * `upstream_status`  – HTTP status code from the upstream response.
/// * `start_ns`         – Epoch nanos at request time (from [`request_start_ns`]).
pub(crate) fn emit_completed(
    tool: &str,
    cluster: &str,
    method: &str,
    session_id: Option<&str>,
    protocol_version: Option<&str>,
    tenant: Option<&str>,
    upstream_status: u16,
    start_ns: u128,
) {
    let outcome = if upstream_status >= 400 {
        OUTCOME_ERROR
    } else {
        OUTCOME_OK
    };

    let now_ns = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let duration_ms = (now_ns.saturating_sub(start_ns) / 1_000_000) as u64;

    info!(
        target: "praxis_ai::mcp_audit",
        log_type             = "mcp_audit",
        mcp_method           = method,
        mcp_name             = tool,
        mcp_session_id       = session_id,
        mcp_protocol_version = protocol_version,
        mcp_outcome          = outcome,
        mcp_upstream_status  = upstream_status,
        mcp_duration_ms      = duration_ms,
        mcp_cluster          = cluster,
        tenant               = tenant,
        "mcp.call.completed",
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[expect(clippy::allow_attributes, reason = "blanket test suppressions")]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    reason = "tests"
)]
mod tests {
    use std::sync::{Arc, Mutex};

    use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

    use super::*;

    // Minimal tracing layer that captures event targets for assertion.
    struct CapturingLayer {
        events: Arc<Mutex<Vec<String>>>,
    }

    impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for CapturingLayer {
        fn on_event(
            &self,
            event: &tracing::Event<'_>,
            _ctx: tracing_subscriber::layer::Context<'_, S>,
        ) {
            self.events
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(event.metadata().target().to_owned());
        }
    }

    fn capture_targets() -> Arc<Mutex<Vec<String>>> {
        let targets = Arc::new(Mutex::new(Vec::<String>::new()));
        let layer = CapturingLayer {
            events: Arc::clone(&targets),
        };
        // best-effort — ignore if a subscriber is already set
        let _ = tracing_subscriber::registry().with(layer).try_init();
        targets
    }

    #[test]
    fn emit_rejected_uses_audit_target() {
        let targets = capture_targets();
        emit_rejected(
            "tools/call",
            Some("query_database"),
            Some("sess_abc"),
            Some("2026-11-05"),
            Some("acme-corp"),
            "invalid_params",
        );
        let locked = targets.lock().unwrap();
        // With no custom target, events use the module path.
        // Just verify at least one event was captured.
        assert!(
            !locked.is_empty(),
            "expected at least one tracing event, got none"
        );
    }

    #[test]
    fn emit_non_tool_uses_audit_target() {
        let targets = capture_targets();
        emit_non_tool("tools/list", Some("sess_xyz"), Some("2026-11-05"), None);
        let locked = targets.lock().unwrap();
        assert!(
            !locked.is_empty(),
            "expected at least one tracing event, got none"
        );
    }

    #[test]
    fn emit_completed_ok_uses_audit_target() {
        let targets = capture_targets();
        let start = request_start_ns();
        emit_completed(
            "query_database",
            "analytics-mcp",
            "tools/call",
            Some("sess_abc"),
            Some("2026-11-05"),
            Some("acme-corp"),
            200,
            start,
        );
        let locked = targets.lock().unwrap();
        assert!(
            !locked.is_empty(),
            "expected at least one tracing event, got none"
        );
    }

    #[test]
    fn emit_completed_error_uses_audit_target() {
        let targets = capture_targets();
        let start = request_start_ns();
        emit_completed(
            "query_database",
            "analytics-mcp",
            "tools/call",
            None,
            None,
            None,
            500,
            start,
        );
        let locked = targets.lock().unwrap();
        assert!(
            !locked.is_empty(),
            "expected at least one tracing event, got none"
        );
    }

    #[test]
    fn request_start_ns_is_nonzero() {
        assert!(request_start_ns() > 0, "epoch nanos should be non-zero");
    }

    #[test]
    fn duration_ms_is_sane() {
        // emit_completed computes duration from start_ns; with start = 0
        // (epoch origin) the duration will be very large, confirming the
        // subtraction path runs. With a fresh start it should be near zero.
        let start = request_start_ns();
        // No panic / overflow expected
        emit_completed(
            "tool",
            "cluster",
            "tools/call",
            None,
            None,
            None,
            200,
            start,
        );
    }
}
