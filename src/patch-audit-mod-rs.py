#!/usr/bin/env python3
"""Patch filters/src/agentic/mcp/mod.rs to integrate MCP audit logging (Gap 3).

Run this script from the root of the praxis-proxy/ai checkout, AFTER
patch-mod-rs.py (Gap 1 metrics) has already been applied if you are
applying both together.

Usage:
    python3 src/patch-audit-mod-rs.py

The script is idempotent: re-running it on an already-patched file is safe
and prints "No changes needed".
"""

import re
import sys

MOD_PATH = "filters/src/agentic/mcp/mod.rs"

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
try:
    with open(MOD_PATH, "r") as f:
        content = f.read()
except FileNotFoundError:
    print(f"ERROR: {MOD_PATH} not found. Run from the praxis-proxy/ai root.")
    sys.exit(1)

original = content
patches_applied = []


def applied(name: str, new_content: str) -> str:
    patches_applied.append(name)
    print(f"  [patch] {name}")
    return new_content


# ---------------------------------------------------------------------------
# Patch 1 — Add audit module declaration after "mod broker;"
# ---------------------------------------------------------------------------
if "pub(crate) mod audit;" not in content:
    content = applied(
        "Add `pub(crate) mod audit;`",
        content.replace("mod broker;", "mod broker;\npub(crate) mod audit;"),
    )

# ---------------------------------------------------------------------------
# Patch 2 — Add std::time::SystemTime to imports
# (may already be present if Gap 1 metrics patch was applied)
# ---------------------------------------------------------------------------
if "time::SystemTime" not in content:
    content = applied(
        "Add SystemTime import",
        content.replace(
            "use std::borrow::Cow;",
            "use std::{borrow::Cow, time::SystemTime};",
        ),
    )

# ---------------------------------------------------------------------------
# Patch 3 — Add audit imports after the existing "use self::{...}" block
# ---------------------------------------------------------------------------
AUDIT_IMPORT = (
    "use self::audit::{\n"
    "    META_AUDIT_METHOD, META_AUDIT_PROTOCOL_VERSION, META_AUDIT_SESSION_ID,\n"
    "    META_AUDIT_START_NS, META_AUDIT_TENANT, META_AUDIT_TOOL,\n"
    "    emit_completed, emit_non_tool, emit_rejected, request_start_ns,\n"
    "};"
)

if "emit_rejected" not in content:
    # Find the end of the last "use self::" block
    lines = content.split("\n")
    insert_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith("use self::") or line.strip().startswith("use super::"):
            j = i
            while j < len(lines) and not lines[j].rstrip().endswith(";"):
                j += 1
            insert_idx = j + 1

    if insert_idx is not None:
        lines.insert(insert_idx, AUDIT_IMPORT)
        content = applied("Add audit imports", "\n".join(lines))
    else:
        print("  WARNING [patch 3]: Could not find insertion point for audit imports")

# ---------------------------------------------------------------------------
# Patch 4 — Extract tenant header early in on_request_body
#
# Insert before the first `reject_missing_required_selector` call.
# ---------------------------------------------------------------------------
TENANT_EXTRACT = (
    'let tenant_header = ctx.request.headers\n'
    '            .get("x-tenant-id")\n'
    '            .and_then(|v| v.to_str().ok());\n\n        '
)

if "tenant_header" not in content:
    target = "if let Some(action) = reject_missing_required_selector("
    if target in content:
        content = applied(
            "Extract tenant_header before first rejection check",
            content.replace(target, TENANT_EXTRACT + target, 1),
        )
    else:
        print("  WARNING [patch 4]: Could not find reject_missing_required_selector call")

# ---------------------------------------------------------------------------
# Patch 5 — Emit audit event at invalid_params rejection path
#
# Wraps the existing early-return block to call emit_rejected before returning.
# ---------------------------------------------------------------------------
OLD_MISSING_SELECTOR = (
    "if let Some(action) = reject_missing_required_selector(&mcp_envelope, &parsed.envelope, &self.config) {\n"
    "            return Ok(action);\n"
    "        }"
)
NEW_MISSING_SELECTOR = (
    "if let Some(action) = reject_missing_required_selector(&mcp_envelope, &parsed.envelope, &self.config) {\n"
    "            emit_rejected(\n"
    "                mcp_envelope.method.as_str(),\n"
    "                mcp_envelope.name.as_deref(),\n"
    "                mcp_envelope.session_id.as_deref(),\n"
    "                mcp_envelope.protocol_version.as_deref(),\n"
    "                tenant_header,\n"
    '                "invalid_params",\n'
    "            );\n"
    "            return Ok(action);\n"
    "        }"
)

if "emit_rejected" not in content or OLD_MISSING_SELECTOR in content:
    if OLD_MISSING_SELECTOR in content:
        content = applied(
            "Add emit_rejected call at invalid_params path",
            content.replace(OLD_MISSING_SELECTOR, NEW_MISSING_SELECTOR, 1),
        )
    else:
        print("  WARNING [patch 5]: Could not find reject_missing_required_selector return block")

# ---------------------------------------------------------------------------
# Patch 6 — Emit audit event at header_mismatch rejection path
# ---------------------------------------------------------------------------
OLD_HEADER_CHECK = (
    "if let Err(action) = validate_mcp_headers(ctx, &mcp_envelope, &parsed.envelope, &self.config) {\n"
    "            return Ok(action);\n"
    "        }"
)
NEW_HEADER_CHECK = (
    "if let Err(action) = validate_mcp_headers(ctx, &mcp_envelope, &parsed.envelope, &self.config) {\n"
    "            emit_rejected(\n"
    "                mcp_envelope.method.as_str(),\n"
    "                mcp_envelope.name.as_deref(),\n"
    "                mcp_envelope.session_id.as_deref(),\n"
    "                mcp_envelope.protocol_version.as_deref(),\n"
    "                tenant_header,\n"
    '                "header_mismatch",\n'
    "            );\n"
    "            return Ok(action);\n"
    "        }"
)

if OLD_HEADER_CHECK in content:
    content = applied(
        "Add emit_rejected call at header_mismatch path",
        content.replace(OLD_HEADER_CHECK, NEW_HEADER_CHECK, 1),
    )

# ---------------------------------------------------------------------------
# Patch 7 — Add audit emit in the success path of on_request_body
#
# Inserted AFTER the existing trace! call (and after Gap 1 metrics code if
# present). Differentiates tools/call (store metadata for response phase)
# from other methods (emit non_tool event immediately).
# ---------------------------------------------------------------------------
AUDIT_SUCCESS = '''
        // ── MCP audit (request phase) ──────────────────────────────────────
        // For tools/call: store context in metadata; response-phase emit
        //   will record outcome, status, and latency.
        // For all other methods: emit the complete audit event now, since
        //   there is no tool-call response to follow up with.
        if matches!(mcp_envelope.method, McpMethod::ToolsCall) {
            ctx.set_metadata(META_AUDIT_METHOD, mcp_envelope.method.as_str());
            if let Some(ref name) = mcp_envelope.name {
                ctx.set_metadata(META_AUDIT_TOOL, name.clone());
            }
            if let Some(ref sid) = mcp_envelope.session_id {
                ctx.set_metadata(META_AUDIT_SESSION_ID, sid.clone());
            }
            if let Some(ref pv) = mcp_envelope.protocol_version {
                ctx.set_metadata(META_AUDIT_PROTOCOL_VERSION, pv.clone());
            }
            if let Some(tenant) = tenant_header {
                ctx.set_metadata(META_AUDIT_TENANT, tenant);
            }
            ctx.set_metadata(META_AUDIT_START_NS, request_start_ns().to_string());
        } else {
            emit_non_tool(
                mcp_envelope.method.as_str(),
                mcp_envelope.session_id.as_deref(),
                mcp_envelope.protocol_version.as_deref(),
                tenant_header,
            );
        }'''

if "META_AUDIT_START_NS" not in content:
    # Find the final Ok(FilterAction::Release) in on_request_body and insert before it.
    # The trace! call and any Gap 1 metrics code precede this return.
    release_pattern = r'(\n        Ok\(FilterAction::Release\))'
    match = re.search(release_pattern, content)
    if match:
        insert_at = match.start(1)
        content = applied(
            "Add audit context storage / non-tool emit in success path",
            content[:insert_at] + AUDIT_SUCCESS + content[insert_at:],
        )
    else:
        print("  WARNING [patch 7]: Could not find Ok(FilterAction::Release)")

# ---------------------------------------------------------------------------
# Patch 8 — Add audit emit in on_response
#
# If Gap 1 already added on_response, we insert audit code inside it
# before the final Ok(FilterAction::Continue).  If on_response doesn't
# exist yet we create it containing only the audit logic (and an explicit
# note to integrate with Gap 1 metrics if needed).
# ---------------------------------------------------------------------------
AUDIT_RESPONSE_INNER = '''
        // ── MCP audit (response phase) ─────────────────────────────────────
        // Fires only for tools/call requests that stored metadata in the
        // request phase above.
        if let Some(method) = ctx.get_metadata(META_AUDIT_METHOD) {
            if let Some(start_ns_str) = ctx.get_metadata(META_AUDIT_START_NS) {
                let start_ns: u128 = start_ns_str.parse().unwrap_or(0);
                let tool = ctx.get_metadata(META_AUDIT_TOOL).unwrap_or("unknown");
                let cluster = ctx.cluster_name().unwrap_or("unknown");
                let session_id = ctx
                    .get_metadata(META_AUDIT_SESSION_ID)
                    .filter(|s| !s.is_empty());
                let protocol_version = ctx
                    .get_metadata(META_AUDIT_PROTOCOL_VERSION)
                    .filter(|s| !s.is_empty());
                let tenant = ctx
                    .get_metadata(META_AUDIT_TENANT)
                    .filter(|s| !s.is_empty());
                let upstream_status = ctx
                    .response_header
                    .as_ref()
                    .map_or(200u16, |r| r.status.as_u16());

                emit_completed(
                    tool,
                    cluster,
                    &method,
                    session_id.as_deref(),
                    protocol_version.as_deref(),
                    tenant.as_deref(),
                    upstream_status,
                    start_ns,
                );
            }
        }
'''

AUDIT_RESPONSE_STANDALONE = (
    "\n    async fn on_response(\n"
    "        &self,\n"
    "        ctx: &mut HttpFilterContext<'_>,\n"
    "    ) -> Result<FilterAction, FilterError> {"
    + AUDIT_RESPONSE_INNER
    + "        Ok(FilterAction::Continue)\n"
    "    }\n"
)

if "META_AUDIT_METHOD" not in content or "emit_completed" not in content.split("fn on_response")[1] if "fn on_response" in content else True:
    if "fn on_response" in content:
        # Gap 1 already added on_response — insert audit code before the
        # final Ok(FilterAction::Continue) inside that function.
        # Strategy: find the LAST Ok(FilterAction::Continue) before the
        # closing brace of on_response.
        on_resp_start = content.index("fn on_response")
        # Find the matching closing brace
        brace_depth = 0
        on_resp_body_start = content.index("{", on_resp_start)
        for i in range(on_resp_body_start, len(content)):
            if content[i] == "{":
                brace_depth += 1
            elif content[i] == "}":
                brace_depth -= 1
                if brace_depth == 0:
                    on_resp_end = i
                    break

        on_resp_body = content[on_resp_body_start:on_resp_end]
        # Find last Ok(FilterAction::Continue) in the body
        last_ok = on_resp_body.rfind("Ok(FilterAction::Continue)")
        if last_ok != -1 and "emit_completed" not in on_resp_body:
            insert_global = on_resp_body_start + last_ok
            content = applied(
                "Insert audit emit inside existing on_response (Gap 1 integration)",
                content[:insert_global] + AUDIT_RESPONSE_INNER + "        " + content[insert_global:],
            )
        elif "emit_completed" in on_resp_body:
            print("  [patch 8] on_response audit already present — skipped")
        else:
            print("  WARNING [patch 8]: Could not find Ok(FilterAction::Continue) in on_response")
    else:
        # No on_response yet — create it
        impl_match = re.search(r'impl\s+HttpFilter\s+for\s+McpFilter', content)
        if impl_match:
            pos = impl_match.start()
            brace_count = 0
            impl_end = None
            for i in range(pos, len(content)):
                if content[i] == "{":
                    brace_count += 1
                elif content[i] == "}":
                    brace_count -= 1
                    if brace_count == 0:
                        impl_end = i
                        break
            if impl_end is not None:
                content = applied(
                    "Create on_response with audit emit (no prior Gap 1 on_response)",
                    content[:impl_end] + AUDIT_RESPONSE_STANDALONE + "\n" + content[impl_end:],
                )
            else:
                print("  WARNING [patch 8]: Could not find end of HttpFilter impl block")
        else:
            print("  WARNING [patch 8]: Could not find HttpFilter impl for McpFilter")

# ---------------------------------------------------------------------------
# Write out if changed
# ---------------------------------------------------------------------------
if content != original:
    with open(MOD_PATH, "w") as f:
        f.write(content)
    print(f"\n  {len(patches_applied)} patch(es) applied to {MOD_PATH}")
else:
    print(f"\n  No changes needed — {MOD_PATH} already up to date")
