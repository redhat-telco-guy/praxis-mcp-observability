#!/usr/bin/env python3
"""Patch filters/src/agentic/mcp/mod.rs to integrate MCP metrics."""

import re

mod_path = "filters/src/agentic/mcp/mod.rs"
with open(mod_path, "r") as f:
    content = f.read()

original = content

# Patch 1: Add metrics module declaration after "mod broker;"
if "pub(crate) mod metrics;" not in content:
    content = content.replace("mod broker;", "mod broker;\npub(crate) mod metrics;")
    print("  [patch 1] Added mod metrics declaration")

# Patch 2: Add SystemTime to imports
if "time::SystemTime" not in content:
    content = content.replace(
        "use std::borrow::Cow;",
        "use std::{borrow::Cow, time::SystemTime};"
    )
    print("  [patch 2] Added SystemTime import")

# Patch 3: Add metrics imports (include record_tool_call_completed for on_response)
if "record_mcp_request" not in content:
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
            "    META_MCP_REQUEST_START_NS, META_MCP_TOOL_NAME,\n"
            "};\n"
            "use self::envelope::McpMethod;"
        )
        lines.insert(insert_idx, metrics_import)
        content = "\n".join(lines)
        print("  [patch 3] Added metrics imports")
    else:
        print("  [patch 3] WARNING: Could not find insertion point")

# Patch 4: Record request metrics after trace! in on_request_body
if "record_mcp_request(" not in content:
    trace_pattern = r'(trace!\([^;]*\);)'
    match = re.search(trace_pattern, content, re.DOTALL)
    if match:
        trace_end = match.end()
        metrics_code = '''

        // ── MCP metrics (request phase) ──
        let method_str = mcp_envelope.method.as_str();
        let pv = mcp_envelope
            .protocol_version
            .as_deref()
            .unwrap_or("unknown");
        record_mcp_request(method_str, pv);

        // For tools/call, store the start time and tool name for response-phase metrics.
        if matches!(mcp_envelope.method, McpMethod::ToolsCall) {
            let epoch_ns = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            ctx.set_metadata(META_MCP_REQUEST_START_NS, epoch_ns.to_string());
            if let Some(ref name) = mcp_envelope.name {
                ctx.set_metadata(META_MCP_TOOL_NAME, name.clone());
            }
        }'''
        content = content[:trace_end] + metrics_code + content[trace_end:]
        print("  [patch 4] Added request metrics recording")
    else:
        print("  [patch 4] WARNING: Could not find trace! call")

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
        content = content.replace(
            "return Some(mcp_invalid_params_rejection(",
            'record_filter_rejection(mcp.method.as_str(), "invalid_params");\n                return Some(mcp_invalid_params_rejection('
        )
        print("  [patch 5] Added invalid_params rejection metric (return pattern)")

# Patch 6: Record rejection for header_mismatch
# Handle "return Err(...)" pattern
if 'record_filter_rejection("unknown", "header_mismatch")' not in content:
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
    print("  [patch 6] Added header_mismatch rejection metric")

# Patch 6b: Record rejection for missing_header
# Pattern: MissingHeaderBehavior::Reject => { return Err(FilterAction::Reject(Rejection::status(400))); }
if 'record_filter_rejection("unknown", "missing_header")' not in content:
    # Try regex with flexible whitespace
    p6b = re.search(
        r'(MissingHeaderBehavior::Reject\s*=>\s*\{?\s*\n?\s*)(return\s+Err\(FilterAction::Reject\(Rejection::status\(400\)\)\))',
        content
    )
    if p6b:
        insert_at = p6b.start(2)
        content = content[:insert_at] + 'record_filter_rejection("unknown", "missing_header");\n' + ' ' * (insert_at - content.rfind('\n', 0, insert_at) - 1) + content[insert_at:]
        print("  [patch 6b] Added missing_header rejection metric (regex match)")
    else:
        # Fallback: try exact string
        content = content.replace(
            "MissingHeaderBehavior::Reject => {\n                return Err(FilterAction::Reject(Rejection::status(400)));",
            'MissingHeaderBehavior::Reject => {\n                record_filter_rejection("unknown", "missing_header");\n                return Err(FilterAction::Reject(Rejection::status(400)));'
        )
        print("  [patch 6b] Added missing_header rejection metric (exact match fallback)")
    # Diagnostic: show if the pattern exists at all
    if 'MissingHeaderBehavior::Reject' in content:
        idx = content.index('MissingHeaderBehavior::Reject')
        print(f"  [patch 6b] DIAG: code around MissingHeaderBehavior::Reject:")
        print(f"  {repr(content[idx:idx+200])}")
    else:
        print("  [patch 6b] WARNING: MissingHeaderBehavior::Reject not found in code at all")

# Patch 6c: Record rejection for invalid JSON-RPC (parser rejection in on_request_body)
# This is the code path triggered by the dashboard "Send Malformed Request" button!
# We need to find ANY "Err(action) => return action" or "Err(e) => return e" pattern
if 'record_filter_rejection("unknown", "invalid_jsonrpc")' not in content:
    # Diagnostic: show ALL Err(...) => return patterns in the file
    err_matches = list(re.finditer(r'Err\(\w+\)\s*=>\s*\{?\s*return\s+\w+', content))
    print(f"  [patch 6c] DIAG: Found {len(err_matches)} 'Err(x) => return' patterns:")
    for m in err_matches:
        ctx_start = max(0, m.start() - 40)
        ctx_end = min(len(content), m.end() + 60)
        print(f"    at pos {m.start()}: {repr(content[ctx_start:ctx_end])}")

    # Also check for "Err(action) =>" without return (direct expression)
    err_matches2 = list(re.finditer(r'Err\((\w+)\)\s*=>\s*(?!return)', content))
    print(f"  [patch 6c] DIAG: Found {len(err_matches2)} 'Err(x) => <expr>' patterns (no return):")
    for m in err_matches2:
        ctx_start = max(0, m.start() - 40)
        ctx_end = min(len(content), m.end() + 80)
        print(f"    at pos {m.start()}: {repr(content[ctx_start:ctx_end])}")

    # Try multiple patterns, from most specific to most general
    patched_6c = False

    # Pattern A: "Err(action) => return action,"
    if not patched_6c and "Err(action) => return action," in content:
        content = content.replace(
            "Err(action) => return action,",
            'Err(action) => {\n                record_filter_rejection("unknown", "invalid_jsonrpc");\n                return action;\n            },'
        )
        patched_6c = True
        print("  [patch 6c] Applied via pattern A: Err(action) => return action,")

    # Pattern B: "Err(action) => return action" (no trailing comma - might be last arm)
    if not patched_6c and re.search(r'Err\(action\)\s*=>\s*return\s+action\b', content):
        content = re.sub(
            r'Err\(action\)\s*=>\s*return\s+action\b',
            'Err(action) => {\n                record_filter_rejection("unknown", "invalid_jsonrpc");\n                return action;\n            }',
            content,
            count=1
        )
        patched_6c = True
        print("  [patch 6c] Applied via pattern B: regex Err(action) => return action")

    # Pattern C: "Err(e) => return e," (different variable name)
    if not patched_6c and re.search(r'Err\((\w+)\)\s*=>\s*return\s+\1', content):
        m = re.search(r'Err\((\w+)\)\s*=>\s*return\s+\1', content)
        var = m.group(1)
        content = re.sub(
            r'Err\((' + var + r')\)\s*=>\s*return\s+\1',
            r'Err(\1) => {\n                record_filter_rejection("unknown", "invalid_jsonrpc");\n                return \1;\n            }',
            content,
            count=1
        )
        patched_6c = True
        print(f"  [patch 6c] Applied via pattern C: Err({var}) => return {var}")

    # Pattern D: "Err(action) => action," (no return keyword, just expression)
    if not patched_6c and re.search(r'Err\((\w+)\)\s*=>\s*\1\s*,', content):
        m = re.search(r'Err\((\w+)\)\s*=>\s*\1\s*,', content)
        var = m.group(1)
        content = re.sub(
            r'Err\((' + var + r')\)\s*=>\s*\1\s*,',
            r'Err(\1) => {\n                record_filter_rejection("unknown", "invalid_jsonrpc");\n                \1\n            },',
            content,
            count=1
        )
        patched_6c = True
        print(f"  [patch 6c] Applied via pattern D: Err({var}) => {var},")

    if not patched_6c:
        print("  [patch 6c] WARNING: Could not find any Err pattern to patch!")
        print("  [patch 6c] Searching for 'on_request_body' to show the function...")
        fn_match = re.search(r'fn\s+on_request_body', content)
        if fn_match:
            # Print 60 lines after fn on_request_body
            fn_start = fn_match.start()
            snippet_end = content.find('\n', fn_start)
            for _ in range(60):
                next_nl = content.find('\n', snippet_end + 1)
                if next_nl == -1:
                    break
                snippet_end = next_nl
            print(f"  {repr(content[fn_start:snippet_end])}")

# Patch 7: Add on_response method
# Uses directly imported names (no metrics:: prefix) to avoid unused-qualifications lint
if "fn on_response" not in content:
    on_response_code = '''
    async fn on_response(
        &self,
        ctx: &mut HttpFilterContext<'_>,
    ) -> Result<FilterAction, FilterError> {
        // Only record duration for tool calls that stored a start time.
        if let Some(start_ns_str) = ctx.get_metadata(META_MCP_REQUEST_START_NS) {
            if let Ok(start_ns) = start_ns_str.parse::<u128>() {
                let now_ns = SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                let duration_seconds = (now_ns.saturating_sub(start_ns)) as f64 / 1_000_000_000.0;

                let tool = ctx
                    .get_metadata(META_MCP_TOOL_NAME)
                    .unwrap_or("unknown");
                let cluster = ctx
                    .cluster_name()
                    .unwrap_or("unknown");
                let is_error = ctx
                    .response_header
                    .as_ref()
                    .map_or(false, |r| r.status.as_u16() >= 400);
                let status = if is_error { "error" } else { "ok" };

                record_tool_call_completed(tool, cluster, status, duration_seconds);
            }
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

if content != original:
    with open(mod_path, "w") as f:
        f.write(content)
    print("  All patches applied to mod.rs")
else:
    print("  No changes needed (patches already applied?)")
