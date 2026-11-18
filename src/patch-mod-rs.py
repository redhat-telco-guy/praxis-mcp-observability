#!/usr/bin/env python3
"""Patch filters/src/agentic/mcp/mod.rs to integrate MCP metrics."""

import re
import sys

mod_path = "filters/src/agentic/mcp/mod.rs"
with open(mod_path, "r") as f:
    content = f.read()

original = content
errors = []

# Patch 1: Add metrics module declaration after "mod broker;"
if "pub(crate) mod metrics;" not in content:
    content = content.replace("mod broker;", "mod broker;\npub(crate) mod metrics;")
    print("  [patch 1] Added mod metrics declaration")

# Patch 2: Add Instant to imports (monotonic clock for duration measurement)
if "time::Instant" not in content:
    content = content.replace(
        "use std::borrow::Cow;",
        "use std::{borrow::Cow, time::Instant};"
    )
    print("  [patch 2] Added Instant import")

# Patch 3: Add metrics imports (include record_tool_call_completed for on_response)
# Also handle the case where old-style imports (META_MCP_*) exist and need replacing.
if "META_MCP_REQUEST_START_NS" in content or "META_MCP_TOOL_NAME" in content:
    import re
    content = re.sub(
        r'use self::metrics::\{[^}]*META_MCP_[^}]*\};',
        'use self::metrics::{\n'
        '    record_mcp_request, record_filter_rejection, record_tool_call_completed,\n'
        '    McpMetricsState,\n'
        '};',
        content,
        flags=re.DOTALL,
    )
    print("  [patch 3] Replaced old META_MCP_* imports with McpMetricsState")
elif "record_mcp_request" not in content:
    lines = content.split("\n")
    insert_idx = None
    for i, line in enumerate(lines):
        if "use self::" in line or "use super::" in line:
            j = i
            while j < len(lines) and not lines[j].rstrip().endswith(";"):
                j += 1
            insert_idx = j + 1
    if insert_idx:
        metrics_import = (
            "use self::metrics::{\n"
            "    record_mcp_request, record_filter_rejection, record_tool_call_completed,\n"
            "    McpMetricsState,\n"
            "};\n"
            "use self::envelope::McpMethod;"
        )
        lines.insert(insert_idx, metrics_import)
        content = "\n".join(lines)
        print("  [patch 3] Added metrics imports")
    else:
        errors.append("patch 3: Could not find insertion point for metrics imports")

# Patch 3b: Replace old ctx.set_metadata(META_MCP_*) with insert_filter_state
if "ctx.set_metadata(META_MCP_REQUEST_START_NS" in content:
    old_block_re = re.compile(
        r'// For tools/call.*?ctx\.set_metadata\(META_MCP_TOOL_NAME.*?\n\s*\}\n\s*\}',
        re.DOTALL,
    )
    new_block = (
        '// For tools/call, store per-instance metrics state for the response phase.\n'
        '        // Uses filter_state (keyed by current_filter_id) so two MCP filter\n'
        '        // instances in the same pipeline do not overwrite each other.\n'
        '        if matches!(mcp_envelope.method, McpMethod::ToolsCall) {\n'
        '            let tool_name = mcp_envelope\n'
        '                .name\n'
        '                .clone()\n'
        '                .unwrap_or_else(|| "unknown".to_owned());\n'
        '            ctx.insert_filter_state(McpMetricsState {\n'
        '                start: Instant::now(),\n'
        '                tool_name,\n'
        '            });\n'
        '        }'
    )
    content = old_block_re.sub(new_block, content)
    print("  [patch 3b] Replaced old set_metadata with insert_filter_state")

# Patch 3c: Replace old ctx.get_metadata(META_MCP_*) response block
if "ctx.get_metadata(META_MCP_REQUEST_START_NS)" in content:
    old_resp_re = re.compile(
        r'// Only record duration.*?record_tool_call_completed\([^)]*\);\n\s*\}\n\s*\}',
        re.DOTALL,
    )
    new_resp = (
        '// Only record duration for tool calls that stored metrics state.\n'
        '        // Uses filter_state (per-instance) so two MCP filters in the same\n'
        '        // pipeline each track their own tool call independently.\n'
        '        if let Some(state) = ctx.get_filter_state::<McpMetricsState>() {\n'
        '            let duration_seconds = state.start.elapsed().as_secs_f64();\n'
        '\n'
        '            let tool = &state.tool_name;\n'
        '            let cluster = ctx\n'
        '                .cluster_name()\n'
        '                .unwrap_or("unknown");\n'
        '\n'
        '            // transport_status reflects HTTP status only. JSON-RPC\n'
        '            // application errors inside HTTP 200 are recorded as "ok".\n'
        '            let is_error = ctx\n'
        '                .response_header\n'
        '                .as_ref()\n'
        '                .map_or(false, |r| r.status.as_u16() >= 400);\n'
        '            let transport_status = if is_error { "error" } else { "ok" };\n'
        '\n'
        '            record_tool_call_completed(tool, cluster, transport_status, duration_seconds);\n'
        '        }'
    )
    content = old_resp_re.sub(new_resp, content)
    print("  [patch 3c] Replaced old get_metadata response block with get_filter_state")

# Patch 4a: Record request metrics immediately after envelope extraction.
# Inserted BEFORE selector/header validation so rejected requests are
# still counted in praxis_mcp_requests_total.
if "record_mcp_request(" not in content:
    env_idx = content.find('= extract_mcp_envelope(')
    if env_idx >= 0:
        # Find the closing brace of the extraction match block.
        match_start = content.find('{', env_idx)
        if match_start is not None and match_start >= 0:
            depth = 1
            i = match_start + 1
            while i < len(content) and depth > 0:
                if content[i] == '{':
                    depth += 1
                elif content[i] == '}':
                    depth -= 1
                i += 1
            # Skip optional ';' and whitespace after closing '}'
            while i < len(content) and content[i] in ' \t':
                i += 1
            if i < len(content) and content[i] == ';':
                i += 1
            early_metrics = '''

        // ── MCP metrics (request phase) ──
        // Recorded before selector/header validation so rejected requests
        // are still counted in praxis_mcp_requests_total.
        let method_str = mcp_envelope.method.as_str();
        let pv = mcp_envelope
            .protocol_version
            .as_deref()
            .unwrap_or("unknown");
        record_mcp_request(method_str, pv);'''
            content = content[:i] + early_metrics + content[i:]
            print("  [patch 4a] Added record_mcp_request before validation")
        else:
            errors.append("patch 4a: Could not find opening brace for extraction match")
    else:
        errors.append("patch 4a: Could not find extract_mcp_envelope call")

# Patch 4b: Store per-instance filter state for tools/call after trace!.
# This needs the routing decision context, so it stays after validation.
if "insert_filter_state(McpMetricsState" not in content:
    trace_pattern = r'(trace!\([^;]*\);)'
    match = re.search(trace_pattern, content, re.DOTALL)
    if match:
        trace_end = match.end()
        state_code = '''

        // For tools/call, store per-instance metrics state for the response phase.
        // Uses filter_state (keyed by current_filter_id) so two MCP filter
        // instances in the same pipeline do not overwrite each other.
        if matches!(mcp_envelope.method, McpMethod::ToolsCall) {
            let tool_name = mcp_envelope
                .name
                .clone()
                .unwrap_or_else(|| "unknown".to_owned());
            ctx.insert_filter_state(McpMetricsState {
                start: Instant::now(),
                tool_name,
            });
        }'''
        content = content[:trace_end] + state_code + content[trace_end:]
        print("  [patch 4b] Added insert_filter_state for tools/call")
    else:
        errors.append("patch 4b: Could not find trace! call in on_request_body")

# Patch 5: Record rejection for invalid_params
# This is inside a match arm: "=> Some(mcp_invalid_params_rejection(...))"
# We need to wrap it in a block: "=> { record_...; Some(...) }"
if 'record_filter_rejection(mcp.method.as_str(), "invalid_params")' not in content:
    # Use regex to find the full match arm and wrap in block
    # Pattern: => Some(mcp_invalid_params_rejection(ARGS))
    patched = re.sub(
        r'=>\s*Some\(mcp_invalid_params_rejection\(([^)]*)\)\)',
        r'=> {\n                    record_filter_rejection(mcp.method.as_str(), "invalid_params");\n                    Some(mcp_invalid_params_rejection(\1))\n                }',
        content
    )
    if patched != content:
        content = patched
        print("  [patch 5] Added invalid_params rejection metric (match arm block)")
    else:
        # Fallback: try "return Some(" pattern
        before = content
        content = content.replace(
            "return Some(mcp_invalid_params_rejection(",
            'record_filter_rejection(mcp.method.as_str(), "invalid_params");\n                return Some(mcp_invalid_params_rejection('
        )
        if content != before:
            print("  [patch 5] Added invalid_params rejection metric (return pattern)")
        else:
            errors.append("patch 5: Could not find invalid_params rejection site")

# Patch 6: Record rejection for header_mismatch
# Pass method from the envelope context where available; fall back to "unknown"
# only when the method has not been parsed yet.
if 'record_filter_rejection(' not in content or '"header_mismatch"' not in content:
    before_6 = content
    if "return Err(mcp_header_mismatch_rejection(" in content:
        content = content.replace(
            "return Err(mcp_header_mismatch_rejection(",
            'record_filter_rejection("unknown", "header_mismatch");\n                return Err(mcp_header_mismatch_rejection('
        )
    else:
        content = content.replace(
            "Err(mcp_header_mismatch_rejection(",
            'record_filter_rejection("unknown", "header_mismatch");\n                Err(mcp_header_mismatch_rejection('
        )
    if content != before_6:
        print("  [patch 6] Added header_mismatch rejection metric")
    else:
        errors.append("patch 6: Could not find header_mismatch rejection site")

# Patch 6b: Record rejection for missing_header
if 'record_filter_rejection(' not in content or '"missing_header"' not in content:
    before_6b = content
    p6b = re.search(
        r'(MissingHeaderBehavior::Reject\s*=>\s*\{?\s*\n?\s*)(return\s+Err\(FilterAction::Reject\(Rejection::status\(400\)\)\))',
        content
    )
    if p6b:
        insert_at = p6b.start(2)
        content = content[:insert_at] + 'record_filter_rejection("unknown", "missing_header");\n' + ' ' * (insert_at - content.rfind('\n', 0, insert_at) - 1) + content[insert_at:]
        print("  [patch 6b] Added missing_header rejection metric")
    else:
        content = content.replace(
            "MissingHeaderBehavior::Reject => {\n                return Err(FilterAction::Reject(Rejection::status(400)));",
            'MissingHeaderBehavior::Reject => {\n                record_filter_rejection("unknown", "missing_header");\n                return Err(FilterAction::Reject(Rejection::status(400)));'
        )
        if content != before_6b:
            print("  [patch 6b] Added missing_header rejection metric (fallback)")
        else:
            errors.append("patch 6b: Could not find missing_header rejection site")

# Patch 6d: Pass parsed method into validate_single_header and use it in rejection metrics.
# After patches 6/6b have been applied, they inserted record_filter_rejection("unknown", ...)
# in the header validation functions.  This patch:
#   1. Adds `let method = mcp.method.as_str();` in validate_mcp_headers
#   2. Passes `method` through to validate_single_header call sites
#   3. Adds `method: &str` parameter to validate_single_header signature
#   4. Replaces "unknown" with `method` in all header-validation rejection calls
if 'record_filter_rejection("unknown", "header_mismatch")' in content or \
   'record_filter_rejection("unknown", "missing_header")' in content:
    patched_6d = False

    # Step 1: In validate_mcp_headers, extract method before first call
    old_call = 'validate_single_header(ctx, "mcp-method", mcp.method.as_str(), envelope, config)?;'
    new_call = (
        'let method = mcp.method.as_str();\n'
        '    validate_single_header(ctx, "mcp-method", method, method, envelope, config)?;'
    )
    if old_call in content:
        content = content.replace(old_call, new_call)
        patched_6d = True

    # Step 2: Update the mcp-name call site to pass method
    old_name_call = 'validate_single_header(ctx, "mcp-name", name, envelope, config)?;'
    new_name_call = 'validate_single_header(ctx, "mcp-name", name, method, envelope, config)?;'
    if old_name_call in content:
        content = content.replace(old_name_call, new_name_call)

    # Step 3: Add method parameter to validate_single_header signature
    old_sig = 'body_value: &str,\n    envelope:'
    new_sig = 'body_value: &str,\n    method: &str,\n    envelope:'
    if old_sig in content and 'method: &str,' not in content.split('fn validate_single_header')[1].split('{')[0]:
        content = content.replace(old_sig, new_sig, 1)

    # Step 4: Replace "unknown" with method in header-validation rejection calls
    # Only within validate_single_header and validate_mcp_headers
    content = content.replace(
        'record_filter_rejection("unknown", "header_mismatch")',
        'record_filter_rejection(method, "header_mismatch")'
    )
    content = content.replace(
        'record_filter_rejection("unknown", "missing_header")',
        'record_filter_rejection(method, "missing_header")'
    )

    if patched_6d:
        print("  [patch 6d] Passed parsed method into header-validation rejection metrics")

# Patch 6c: Record rejection for invalid JSON-RPC (parser rejection in on_request_body)
# Only record the rejection when the action is actually a Reject, not Continue.
if 'record_filter_rejection(' not in content or '"invalid_jsonrpc"' not in content:
    patched_6c = False

    # Pattern A: "Err(action) => return action,"
    # Wrap in a block that checks whether the action is a reject before counting.
    rejection_block = (
        'Err(action) => {\n'
        '                if matches!(&action, Ok(FilterAction::Reject(_)) | Err(_)) {\n'
        '                    record_filter_rejection("unknown", "invalid_jsonrpc");\n'
        '                }\n'
        '                return action;\n'
        '            },'
    )

    if not patched_6c and "Err(action) => return action," in content:
        content = content.replace("Err(action) => return action,", rejection_block)
        patched_6c = True
        print("  [patch 6c] Added invalid_jsonrpc rejection metric (pattern A)")

    # Pattern B: regex variant
    if not patched_6c and re.search(r'Err\(action\)\s*=>\s*return\s+action\b', content):
        content = re.sub(
            r'Err\(action\)\s*=>\s*return\s+action\b',
            rejection_block.rstrip(','),
            content,
            count=1
        )
        patched_6c = True
        print("  [patch 6c] Added invalid_jsonrpc rejection metric (pattern B)")

    # Pattern C: different variable name
    if not patched_6c and re.search(r'Err\((\w+)\)\s*=>\s*return\s+\1', content):
        m = re.search(r'Err\((\w+)\)\s*=>\s*return\s+\1', content)
        var = m.group(1)
        block_c = (
            f'Err({var}) => {{\n'
            f'                if matches!(&{var}, Ok(FilterAction::Reject(_)) | Err(_)) {{\n'
            f'                    record_filter_rejection("unknown", "invalid_jsonrpc");\n'
            f'                }}\n'
            f'                return {var};\n'
            f'            }}'
        )
        content = re.sub(
            r'Err\(' + var + r'\)\s*=>\s*return\s+' + var + r'\b',
            block_c,
            content,
            count=1
        )
        patched_6c = True
        print(f"  [patch 6c] Added invalid_jsonrpc rejection metric (pattern C)")

    if not patched_6c:
        errors.append("patch 6c: Could not find JSON-RPC error return pattern")

# Patch 7: Add on_response method
# Uses Instant::elapsed() for monotonic duration measurement.
if "fn on_response" not in content:
    on_response_code = '''
    async fn on_response(
        &self,
        ctx: &mut HttpFilterContext<'_>,
    ) -> Result<FilterAction, FilterError> {
        // Only record duration for tool calls that stored metrics state.
        // Uses filter_state (per-instance) so two MCP filters in the same
        // pipeline each track their own tool call independently.
        if let Some(state) = ctx.get_filter_state::<McpMetricsState>() {
            let duration_seconds = state.start.elapsed().as_secs_f64();

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
'''
    impl_match = re.search(r'impl\s+HttpFilter\s+for\s+McpFilter', content)
    if impl_match:
        pos = impl_match.start()
        brace_count = 0
        impl_end = None
        for i in range(pos, len(content)):
            if content[i] == '{':
                brace_count += 1
            elif content[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    impl_end = i
                    break
        if impl_end is not None:
            content = content[:impl_end] + on_response_code + "\n" + content[impl_end:]
            print("  [patch 7] Added on_response method")
        else:
            print("  [patch 7] WARNING: Could not find end of impl block")
    else:
        print("  [patch 7] WARNING: Could not find HttpFilter impl")

if errors:
    print("\n  ERRORS — the following patches could not be applied:")
    for e in errors:
        print(f"    - {e}")
    sys.exit(1)

if content != original:
    with open(mod_path, "w") as f:
        f.write(content)
    print("  All patches applied to mod.rs")
else:
    print("  No changes needed (patches already applied?)")
