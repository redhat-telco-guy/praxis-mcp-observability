// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! MCP protocol metrics emitted by the `mcp` filter.
//!
//! These provide per-tool and per-method observability for MCP traffic
//! routed through Praxis, closing the gap with competing gateways (Kong,
//! Portkey) that ship MCP-specific Prometheus metrics out of the box.
//!
//! # Label cardinality
//!
//! Every label value is drawn from either:
//! - A closed vocabulary (`method` from [`McpMethod`], `transport_status`
//!   from HTTP status classification, `error_code` from JSON-RPC error
//!   codes), or
//! - Bounded configuration (`tool` from the upstream catalog, `cluster`
//!   from proxy config).
//!
//! Tool names are additionally capped at [`MAX_TOOL_LABELS`] distinct
//! values per process lifetime — values arriving after the cap are labeled
//! `"other"`, matching the cardinality-bounding pattern in
//! [`llm_metrics`](crate::llm_metrics).
//!
//! # Metric rationale
//!
//! - `praxis_mcp_requests_total{method, protocol_version}`: request
//!   volumes by MCP method — capacity planning, method mix visibility.
//! - `praxis_mcp_tool_calls_total{tool, cluster, transport_status}`:
//!   per-tool call counts with HTTP transport outcome — error rate
//!   alerting, usage ranking. Note: reflects HTTP status, not JSON-RPC
//!   application-level success.
//! - `praxis_mcp_tool_call_duration_seconds{tool, cluster}`: upstream
//!   round-trip time per tool — latency SLOs, slow-tool detection.
//! - `praxis_mcp_filter_rejections_total{method, reason}`: requests
//!   rejected by the MCP filter itself — misconfiguration, attacks.

use std::{
    collections::HashSet,
    sync::{Arc, Mutex, Once, OnceLock},
};

use arc_swap::ArcSwap;
use metrics::{Unit, counter, describe_histogram, histogram};
use praxis_ai_apis::promotion::contains_control_chars;

// ---------------------------------------------------------------------------
// Metric names
// ---------------------------------------------------------------------------

/// MCP requests by method and protocol version, cumulative.
pub const METRIC_MCP_REQUESTS_TOTAL: &str = "praxis_mcp_requests_total";

/// Tool call invocations by tool name, upstream cluster, and HTTP transport outcome.
///
/// The `transport_status` label reflects the HTTP status code returned by
/// the upstream MCP server (`"ok"` for 2xx/3xx, `"error"` for 4xx/5xx).
/// It does **not** indicate JSON-RPC application-level success: a tool
/// that returns a JSON-RPC `{"error": ...}` inside an HTTP 200 is recorded
/// as `transport_status="ok"`. Detecting application-level errors requires
/// response body parsing, which is out of scope for this transport-level
/// metric.
pub const METRIC_MCP_TOOL_CALLS_TOTAL: &str = "praxis_mcp_tool_calls_total";

/// Upstream round-trip time for tool calls (seconds), histogram.
pub const METRIC_MCP_TOOL_CALL_DURATION: &str = "praxis_mcp_tool_call_duration_seconds";

/// Requests rejected by the MCP filter (invalid params, header mismatch, etc.).
pub const METRIC_MCP_FILTER_REJECTIONS_TOTAL: &str = "praxis_mcp_filter_rejections_total";

// ---------------------------------------------------------------------------
// Per-instance filter state for cross-phase metrics
// ---------------------------------------------------------------------------

/// Per-request metrics state stored in `filter_state` during the request
/// phase and retrieved in the response phase.
///
/// Using `filter_state` (keyed by `current_filter_id`) instead of shared
/// `filter_metadata` ensures that two MCP filter instances in the same
/// pipeline do not overwrite each other's timing or tool name.
pub(crate) struct McpMetricsState {
    /// Wall-clock start time in nanoseconds since epoch.
    pub start_ns: u64,
    /// Tool name extracted from the JSON-RPC `params.name` field.
    pub tool_name: String,
}

// ---------------------------------------------------------------------------
// Tool-name label bounding
// ---------------------------------------------------------------------------

/// Upper bound on distinct `tool` label values admitted per process.
///
/// Tool names originate from the configured upstream catalog and are
/// inherently bounded by configuration, but a misconfigured or malicious
/// client could send arbitrary tool names before the router rejects
/// them. This cap keeps the Prometheus registry bounded regardless.
/// The MCP Gateway design targets ~100 tools per tenant; 512 leaves
/// generous headroom.
pub(crate) const MAX_TOOL_LABELS: usize = 512;

/// Maximum length of a tool name label value. Names longer than this are
/// truncated to prevent unbounded label storage.
const MAX_TOOL_NAME_LEN: usize = 64;

/// Label for tool values that arrive once [`MAX_TOOL_LABELS`] distinct
/// values have been admitted.
const OTHER_TOOL_LABEL: &str = "other";

/// Guards the one-time histogram descriptions.
static DESCRIBED: Once = Once::new();

/// Describe histogram units once.
fn ensure_described() {
    DESCRIBED.call_once(|| {
        describe_histogram!(
            METRIC_MCP_TOOL_CALL_DURATION,
            Unit::Seconds,
            "upstream round-trip time for MCP tool calls"
        );
    });
}

/// Immutable snapshot of admitted tool labels.
static ADMITTED_TOOLS: OnceLock<ArcSwap<HashSet<String>>> = OnceLock::new();

/// Serializes first-time admission.
static TOOL_ADMISSION_LOCK: Mutex<()> = Mutex::new(());

/// Admit `tool` against the process-wide [`MAX_TOOL_LABELS`] bound.
///
/// Fast path (already-admitted) is a lock-free snapshot load.
/// First-time admissions serialize on [`TOOL_ADMISSION_LOCK`].
fn admit_tool(tool: &str) -> &str {
    let cell = ADMITTED_TOOLS.get_or_init(|| ArcSwap::from_pointee(HashSet::new()));

    // Fast path: lock-free membership check.
    {
        let snapshot = cell.load();
        if snapshot.contains(tool) {
            return tool;
        }
    }

    // Slow path: first-time admission.
    let _lock = TOOL_ADMISSION_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut updated = {
        let snapshot = cell.load_full();
        let current: &HashSet<String> = &snapshot;
        if current.contains(tool) {
            return tool;
        }
        if current.len() >= MAX_TOOL_LABELS {
            return OTHER_TOOL_LABEL;
        }
        current.clone()
    };
    updated.insert(tool.to_owned());
    cell.store(Arc::new(updated));
    tool
}

/// Resolve a tool label, applying control-char rejection, length truncation,
/// and cardinality bound.
fn tool_label(tool: &str) -> String {
    if tool.is_empty() || contains_control_chars(tool) {
        return "unknown".to_owned();
    }
    // Truncate to MAX_TOOL_NAME_LEN, respecting UTF-8 char boundaries.
    let truncated = if tool.len() > MAX_TOOL_NAME_LEN {
        match tool.char_indices().nth(MAX_TOOL_NAME_LEN) {
            Some((idx, _)) => &tool[..idx],
            None => tool,
        }
    } else {
        tool
    };
    admit_tool(truncated).to_owned()
}

// ---------------------------------------------------------------------------
// Recording helpers
// ---------------------------------------------------------------------------

/// Recognized MCP methods. Anything else is mapped to `"other"`.
const KNOWN_METHODS: &[&str] = &[
    "tools/call",
    "tools/list",
    "initialize",
    "initialized",
    "ping",
    "resources/list",
    "resources/read",
    "prompts/list",
    "prompts/get",
    "completion/complete",
    "notifications/cancelled",
    "notifications/progress",
];

/// Map an MCP method to a bounded label value.
fn sanitize_method(method: &str) -> &str {
    if KNOWN_METHODS.contains(&method) {
        method
    } else {
        "other"
    }
}

/// Map a protocol version to a bounded label value.
/// Accepts recognized version strings; everything else becomes `"unknown"`.
fn sanitize_protocol_version(pv: &str) -> &str {
    // Accept ISO-date-shaped versions (e.g. "2024-11-05", "2025-11-25")
    // and the literal "unknown".
    if pv == "unknown"
        || (pv.len() == 10
            && pv.as_bytes().get(4) == Some(&b'-')
            && pv.as_bytes().get(7) == Some(&b'-')
            && pv.bytes().filter(|b| b.is_ascii_digit()).count() == 8)
    {
        pv
    } else {
        "unknown"
    }
}

/// Record one MCP request by method and protocol version.
///
/// Called from `on_request_body` after successful JSON-RPC extraction.
/// `method` is mapped to a closed set via [`sanitize_method`];
/// `protocol_version` is validated via [`sanitize_protocol_version`].
pub fn record_mcp_request(method: &str, protocol_version: &str) {
    let method = sanitize_method(method);
    let protocol_version = sanitize_protocol_version(protocol_version);
    counter!(
        METRIC_MCP_REQUESTS_TOTAL,
        "method" => method.to_owned(),
        "protocol_version" => protocol_version.to_owned()
    )
    .increment(1);
}

/// Record a completed tool call with its transport outcome and upstream duration.
///
/// Called from the response phase. `transport_status` is `"ok"` or
/// `"error"` derived from the HTTP status code (>= 400 → error).
/// This reflects **transport-level** success only; a JSON-RPC
/// application error inside an HTTP 200 is recorded as `"ok"`.
/// `duration_seconds` is wall-clock time from routing decision to
/// response headers.
pub fn record_tool_call_completed(
    tool: &str,
    cluster: &str,
    transport_status: &str,
    duration_seconds: f64,
) {
    ensure_described();
    let tool = tool_label(tool);
    let cluster = cluster.to_owned();

    counter!(
        METRIC_MCP_TOOL_CALLS_TOTAL,
        "tool" => tool.clone(),
        "cluster" => cluster.clone(),
        "transport_status" => transport_status.to_owned()
    )
    .increment(1);

    histogram!(
        METRIC_MCP_TOOL_CALL_DURATION,
        "tool" => tool,
        "cluster" => cluster
    )
    .record(duration_seconds);
}

/// Recognized rejection reasons. Anything else is mapped to `"other"`.
const KNOWN_REJECTION_REASONS: &[&str] = &[
    "invalid_params",
    "header_mismatch",
    "missing_header",
    "body_too_large",
    "invalid_jsonrpc",
];

/// Record a filter-level rejection (invalid params, header mismatch, etc.).
///
/// Called when the MCP filter returns a `FilterAction::Reject`. Both
/// `method` and `reason` are mapped to closed sets to prevent cardinality
/// explosion.
pub fn record_filter_rejection(method: &str, reason: &str) {
    let method = sanitize_method(method);
    let reason = if KNOWN_REJECTION_REASONS.contains(&reason) {
        reason
    } else {
        "other"
    };
    counter!(
        METRIC_MCP_FILTER_REJECTIONS_TOTAL,
        "method" => method.to_owned(),
        "reason" => reason.to_owned()
    )
    .increment(1);
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
    use metrics_util::debugging::DebuggingRecorder;

    use super::*;

    #[test]
    fn record_mcp_request_emits_labeled_counter() {
        let recorder = DebuggingRecorder::new();
        let snapshotter = recorder.snapshotter();

        metrics::with_local_recorder(&recorder, || {
            record_mcp_request("tools/call", "2025-11-25");
            record_mcp_request("tools/call", "2025-11-25");
            record_mcp_request("tools/list", "2026-07-28");
        });

        let snap = snapshotter.snapshot().into_vec();
        let total = |method: &str, pv: &str| -> u64 {
            snap.iter()
                .filter(|(k, ..)| {
                    k.key().name() == METRIC_MCP_REQUESTS_TOTAL
                        && k.key().labels().any(|l| l.key() == "method" && l.value() == method)
                        && k.key()
                            .labels()
                            .any(|l| l.key() == "protocol_version" && l.value() == pv)
                })
                .filter_map(|(_, _, _, v)| match v {
                    metrics_util::debugging::DebugValue::Counter(c) => Some(*c),
                    _ => None,
                })
                .sum()
        };

        assert_eq!(total("tools/call", "2025-11-25"), 2);
        assert_eq!(total("tools/list", "2026-07-28"), 1);
    }

    #[test]
    fn record_tool_call_completed_emits_counter_and_histogram() {
        let recorder = DebuggingRecorder::new();
        let snapshotter = recorder.snapshotter();

        metrics::with_local_recorder(&recorder, || {
            record_tool_call_completed("weather_lookup", "mcp-weather", "ok", 0.042);
            record_tool_call_completed("weather_lookup", "mcp-weather", "error", 1.5);
        });

        let snap = snapshotter.snapshot().into_vec();

        // Counter check
        let counter_total = |status: &str| -> u64 {
            snap.iter()
                .filter(|(k, ..)| {
                    k.key().name() == METRIC_MCP_TOOL_CALLS_TOTAL
                        && k.key()
                            .labels()
                            .any(|l| l.key() == "tool" && l.value() == "weather_lookup")
                        && k.key()
                            .labels()
                            .any(|l| l.key() == "transport_status" && l.value() == status)
                })
                .filter_map(|(_, _, _, v)| match v {
                    metrics_util::debugging::DebugValue::Counter(c) => Some(*c),
                    _ => None,
                })
                .sum()
        };
        assert_eq!(counter_total("ok"), 1);
        assert_eq!(counter_total("error"), 1);

        // Histogram check — two samples recorded
        let histogram_count: usize = snap
            .iter()
            .filter(|(k, ..)| k.key().name() == METRIC_MCP_TOOL_CALL_DURATION)
            .filter_map(|(_, _, _, v)| match v {
                metrics_util::debugging::DebugValue::Histogram(h) => Some(h.len()),
                _ => None,
            })
            .sum();
        assert_eq!(histogram_count, 2);
    }

    #[test]
    fn record_filter_rejection_emits_labeled_counter() {
        let recorder = DebuggingRecorder::new();
        let snapshotter = recorder.snapshotter();

        metrics::with_local_recorder(&recorder, || {
            record_filter_rejection("tools/call", "invalid_params");
            record_filter_rejection("tools/call", "header_mismatch");
        });

        let snap = snapshotter.snapshot().into_vec();
        let present = |reason: &str| -> bool {
            snap.iter().any(|(k, ..)| {
                k.key().name() == METRIC_MCP_FILTER_REJECTIONS_TOTAL
                    && k.key()
                        .labels()
                        .any(|l| l.key() == "reason" && l.value() == reason)
            })
        };
        assert!(present("invalid_params"));
        assert!(present("header_mismatch"));
    }

    #[test]
    fn tool_label_bounds_cardinality() {
        // Verify that empty tool names map to "unknown"
        assert_eq!(tool_label(""), "unknown");

        // Verify that normal tool names pass through
        let name = format!("test_tool_{}", line!());
        assert_eq!(tool_label(&name), name);
    }

    #[test]
    fn tool_label_truncates_long_names() {
        let long_name = "a".repeat(100);
        let label = tool_label(&long_name);
        assert_eq!(label.len(), MAX_TOOL_NAME_LEN);
        assert_eq!(label, "a".repeat(MAX_TOOL_NAME_LEN));
    }

    #[test]
    fn sanitize_method_rejects_unknown() {
        assert_eq!(sanitize_method("tools/call"), "tools/call");
        assert_eq!(sanitize_method("tools/list"), "tools/list");
        assert_eq!(sanitize_method("initialize"), "initialize");
        assert_eq!(sanitize_method("evil_method"), "other");
        assert_eq!(sanitize_method(""), "other");
    }

    #[test]
    fn sanitize_protocol_version_rejects_garbage() {
        assert_eq!(sanitize_protocol_version("2025-11-25"), "2025-11-25");
        assert_eq!(sanitize_protocol_version("unknown"), "unknown");
        assert_eq!(sanitize_protocol_version("evil"), "unknown");
        assert_eq!(sanitize_protocol_version(""), "unknown");
        assert_eq!(sanitize_protocol_version("99999-99-99"), "unknown");
    }

    #[test]
    fn tool_label_admits_concurrent_values() {
        use std::sync::Barrier;

        const THREADS: usize = 4;
        const PER_THREAD: usize = 8;
        let barrier = Arc::new(Barrier::new(THREADS + 1));
        let mut handles = Vec::new();

        for t in 0..THREADS {
            let barrier = Arc::clone(&barrier);
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                for i in 0..PER_THREAD {
                    let name = format!("concurrent_mcp_t{t}_m{i}");
                    let label = tool_label(&name);
                    // Must be either the original name or "other" (if cap hit)
                    assert!(
                        label == name || label == OTHER_TOOL_LABEL,
                        "unexpected label: {label}"
                    );
                }
            }));
        }
        barrier.wait();
        for h in handles {
            h.join().unwrap();
        }
    }
}
