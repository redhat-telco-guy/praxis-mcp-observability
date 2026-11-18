#!/usr/bin/env bash
# install.sh — Gap 3: MCP Audit Logging, one-shot install
#
# Builds on OCP using the existing praxis-ai-mcp-metrics BuildConfig from Gap 1.
# Applies both Gap 1 (metrics) and Gap 3 (audit) patches, then builds the
# container image directly on the cluster — no local Rust toolchain needed.
#
# Usage:
#   PRAXIS_AI_DIR=/path/to/praxis-proxy/ai bash install.sh
#
# Optional env vars:
#   PROJECT      OCP namespace (default: praxis-mcp-test)
#   GAP1_DIR     Path to praxis-mcp-observability checkout (default: auto-clone)
#   SKIP_BUILD   Set to 1 to skip OCP image build (e.g. already built)
#   SKIP_LOKI    Set to 1 to skip Loki verification
#   BC_NAME      BuildConfig name (default: praxis-ai-mcp-metrics)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${PROJECT:-praxis-mcp-test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_LOKI="${SKIP_LOKI:-1}"
BC_NAME="${BC_NAME:-praxis-ai-mcp-metrics}"
GAP1_DIR="${GAP1_DIR:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${BOLD}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗ $*${NC}"; exit 1; }

echo -e "${BOLD}=== Praxis MCP Audit Logging — Gap 3 Install ===${NC}"
echo "    Script dir:    $SCRIPT_DIR"
echo "    OCP namespace: $PROJECT"
echo "    BuildConfig:   $BC_NAME"

# ── 1. Validate praxis-proxy/ai checkout ─────────────────────────────────────
step "Checking praxis-proxy/ai checkout"
[[ -z "${PRAXIS_AI_DIR:-}" ]] && die "Set PRAXIS_AI_DIR to your praxis-proxy/ai checkout path"
[[ -d "$PRAXIS_AI_DIR/filters/src/agentic/mcp" ]] \
  || die "$PRAXIS_AI_DIR does not look like a praxis-proxy/ai checkout"
ok "Found: $PRAXIS_AI_DIR"

# Reset mod.rs to upstream state so patches apply cleanly.
# Use 'git checkout origin/main' to get the actual upstream file, not a
# locally committed version that may contain stale patches from a prior run.
step "Resetting checkout to clean state"
if command -v git &>/dev/null && [[ -d "$PRAXIS_AI_DIR/.git" ]]; then
  (cd "$PRAXIS_AI_DIR" && git fetch origin 2>/dev/null || true)
  RESET_REF="origin/main"
  if ! (cd "$PRAXIS_AI_DIR" && git rev-parse "$RESET_REF" &>/dev/null); then
    RESET_REF="HEAD"
    warn "origin/main not found — falling back to HEAD"
  fi
  (cd "$PRAXIS_AI_DIR" && git checkout "$RESET_REF" -- filters/src/agentic/mcp/mod.rs Containerfile 2>/dev/null || true)
  rm -f "$PRAXIS_AI_DIR/filters/src/agentic/mcp/metrics.rs" \
        "$PRAXIS_AI_DIR/filters/src/agentic/mcp/audit.rs" \
        "$PRAXIS_AI_DIR/Dockerfile"
  ok "Checkout reset to upstream ($RESET_REF)"
else
  warn "Not a git repo — skipping reset (patches are idempotent)"
fi

# ── 2. Apply Gap 1 (metrics) patches ────────────────────────────────────────
step "Applying Gap 1 patches (MCP Prometheus metrics)"
if [[ -z "$GAP1_DIR" ]]; then
  # Auto-clone if not provided
  GAP1_DIR="$(dirname "$PRAXIS_AI_DIR")/praxis-mcp-observability"
  if [[ ! -d "$GAP1_DIR" ]]; then
    echo "  Cloning Gap 1 repo ..."
    git clone https://github.com/redhat-telco-guy/praxis-mcp-observability.git "$GAP1_DIR"
  fi
fi
[[ -f "$GAP1_DIR/src/metrics.rs" ]] \
  || die "$GAP1_DIR does not contain Gap 1 source (src/metrics.rs missing)"

cp "$GAP1_DIR/src/metrics.rs" "$PRAXIS_AI_DIR/filters/src/agentic/mcp/metrics.rs"
ok "Copied metrics.rs"

cp "$GAP1_DIR/src/patch-mod-rs.py" "$PRAXIS_AI_DIR/patch-gap1-mod-rs.py"
(cd "$PRAXIS_AI_DIR" && python3 patch-gap1-mod-rs.py)
rm -f "$PRAXIS_AI_DIR/patch-gap1-mod-rs.py"
ok "Gap 1 mod.rs patches applied"

# ── 3. Apply Gap 3 (audit) patches ──────────────────────────────────────────
step "Applying Gap 3 patches (MCP audit logging)"
cp "$SCRIPT_DIR/src/audit.rs" "$PRAXIS_AI_DIR/filters/src/agentic/mcp/audit.rs"
ok "Copied audit.rs"

cp "$SCRIPT_DIR/src/patch-audit-mod-rs.py" "$PRAXIS_AI_DIR/patch-audit-mod-rs.py"
(cd "$PRAXIS_AI_DIR" && python3 patch-audit-mod-rs.py)
rm -f "$PRAXIS_AI_DIR/patch-audit-mod-rs.py"
ok "Gap 3 mod.rs patches applied"

# ── 3b. Post-patch fixups ───────────────────────────────────────────────────
step "Running post-patch fixups"
MOD_RS="$PRAXIS_AI_DIR/filters/src/agentic/mcp/mod.rs"

# Fix 0: Add log_audit_enabled to audit imports and inject startup call
if ! grep -q 'log_audit_enabled' "$MOD_RS"; then
  sed -i.bak 's/emit_completed, emit_non_tool, emit_rejected, request_start_ns,/emit_completed, emit_non_tool, emit_rejected, log_audit_enabled, request_start_ns,/' "$MOD_RS"
  rm -f "$MOD_RS.bak"
  # Inject the call at the start of on_request_body (after the function signature opening brace)
  python3 -c "
with open('$MOD_RS', 'r') as f:
    content = f.read()
# Find the first occurrence of on_request_body and inject a one-time init check.
# Use a static AtomicBool so we only log once.
init_block = '''
        // One-time audit startup log
        {
            use std::sync::atomic::{AtomicBool, Ordering};
            static LOGGED: AtomicBool = AtomicBool::new(false);
            if !LOGGED.swap(true, Ordering::Relaxed) {
                log_audit_enabled();
            }
        }
'''
# Insert after 'async fn on_request_body' function's opening lines
target = 'ctx: &mut HttpFilterContext'
# Find on_request_body, then the next occurrence of ctx: &mut
idx = content.find('async fn on_request_body')
if idx is not None:
    # Find the body opening '{'
    brace = content.index('{', content.index(')', idx))
    insert_at = brace + 1
    content = content[:insert_at] + '\n' + init_block + content[insert_at:]
    with open('$MOD_RS', 'w') as f:
        f.write(content)
    print('  Injected log_audit_enabled() startup call')
"
  ok "Added startup log for audit module"
fi

# Fix 1: Remove unnecessary envelope:: qualification (Rust lint -D unused-qualifications)
if grep -q 'envelope::McpMethod::ToolsCall' "$MOD_RS"; then
  sed -i.bak 's/envelope::McpMethod::ToolsCall/McpMethod::ToolsCall/g' "$MOD_RS"
  rm -f "$MOD_RS.bak"
  ok "Fixed envelope:: qualification lint"
fi

# Fix 2: Ensure audit success path (metadata storage + emit_non_tool) is in on_request_body.
# The patch script's regex may fail to insert this after Gap 1's metrics code.
# Check for the actual function call, not just the import.
if ! grep -q 'ctx.set_metadata(META_AUDIT_METHOD' "$MOD_RS"; then
    python3 -c "
with open('$MOD_RS', 'r') as f:
    content = f.read()

AUDIT_SUCCESS = '''
        // ── MCP audit (request phase) ──────────────────────────────────────
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
        }

'''

target = '        Ok(FilterAction::Release)'
if target in content:
    content = content.replace(target, AUDIT_SUCCESS + target, 1)
    with open('$MOD_RS', 'w') as f:
        f.write(content)
    print('  Injected audit success path before Ok(FilterAction::Release)')
else:
    print('  WARNING: Could not find Ok(FilterAction::Release)')
"
    ok "Added audit success path to on_request_body"
else
  ok "Audit success path already present"
fi

# Fix 3: Ensure on_response has BOTH metrics and audit code.
# Gap 1 creates on_response with metrics; Gap 3 may overwrite with audit-only.
# If on_response exists but is missing metrics, inject metrics before audit.
if grep -q 'fn on_response' "$MOD_RS"; then
  if ! grep -q 'record_tool_call_completed' "$MOD_RS"; then
    # Insert Gap 1 metrics block before the audit block in on_response
    python3 -c "
import re
with open('$MOD_RS', 'r') as f:
    content = f.read()

METRICS_RESPONSE = '''
        // ── MCP metrics (response phase) ──────────────────────────────────
        // Record tool call duration and transport status for Prometheus metrics.
        // Uses filter_state (per-instance) so two MCP filters in the same
        // pipeline each track their own tool call independently.
        if let Some(state) = ctx.get_filter_state::<McpMetricsState>() {
            let duration_seconds = state.start.elapsed().as_secs_f64();

            let tool = &state.tool_name;
            let cluster = ctx
                .cluster_name()
                .unwrap_or(\"unknown\");

            // transport_status reflects HTTP status only. JSON-RPC
            // application errors inside HTTP 200 are recorded as \"ok\".
            let is_error = ctx
                .response_header
                .as_ref()
                .map_or(false, |r| r.status.as_u16() >= 400);
            let transport_status = if is_error { \"error\" } else { \"ok\" };

            record_tool_call_completed(tool, cluster, transport_status, duration_seconds);
        }

'''

# Insert before the audit response block
target = '        // ── MCP audit (response phase)'
if target in content:
    content = content.replace(target, METRICS_RESPONSE + target)
    with open('$MOD_RS', 'w') as f:
        f.write(content)
    print('  Injected metrics into on_response')
else:
    print('  WARNING: Could not find audit response marker')
"
    ok "Added Gap 1 metrics to on_response"
  else
    ok "on_response already has both metrics and audit"
  fi
fi

# ── 4. Build on OCP ──────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "1" ]]; then
  warn "Skipping OCP build (SKIP_BUILD=1)"
else
  step "Building Praxis image on OCP"

  # Ensure namespace exists
  oc get ns "$PROJECT" &>/dev/null || oc new-project "$PROJECT"

  # OCP binary builds expect a Dockerfile — symlink from Containerfile
  if [[ -f "$PRAXIS_AI_DIR/Containerfile" ]] && [[ ! -f "$PRAXIS_AI_DIR/Dockerfile" ]]; then
    ln -sf Containerfile "$PRAXIS_AI_DIR/Dockerfile"
    ok "Created Dockerfile symlink → Containerfile"
  fi

  # Patch the Containerfile for OCP builds:
  # 1. Strip BuildKit --mount=type=cache (OCP Buildah doesn't support it reliably)
  # 2. Add fingerprint cleanup between stub build and real build so cargo
  #    recompiles the filters and apis crates with the patched source.
  python3 -c "
import re

cf_path = '$PRAXIS_AI_DIR/Containerfile'
with open(cf_path, 'r') as f:
    content = f.read()

# 1. Strip --mount=type=cache directives
content = re.sub(r'--mount=type=cache[^ ]* *', '', content)

# 2. Insert fingerprint cleanup after the 'touch' step and before the final build.
# This forces cargo to recompile filters/apis instead of using stale stub artifacts.
CLEANUP = '''
# Force recompilation of patched crates (fingerprints are stale from stub build)
RUN rm -rf target/release/.fingerprint/praxis-ai-filters-* \\\\
           target/release/.fingerprint/praxis-ai-apis-* \\\\
           target/release/deps/libpraxis_ai_filters* \\\\
           target/release/deps/libpraxis_ai_apis* \\\\
           target/release/deps/praxis_ai_filters* \\\\
           target/release/deps/praxis_ai_apis*
'''

# Find the touch command and insert after it
touch_pattern = r\"(-name '\*\\.rs' -exec touch \\{\\} \\+)\"
match = re.search(touch_pattern, content)
if match:
    insert_at = match.end()
    # Skip to end of line
    nl = content.index('\n', insert_at)
    content = content[:nl+1] + CLEANUP + content[nl+1:]
    print('  Containerfile patched: cache mounts stripped + fingerprint cleanup added')
else:
    print('  WARNING: Could not find touch command in Containerfile')

with open(cf_path, 'w') as f:
    f.write(content)
"
  ok "Containerfile patched for OCP build"

  # Verify patched source is in the build context before uploading
  if grep -q 'pub(crate) mod audit' "$PRAXIS_AI_DIR/filters/src/agentic/mcp/mod.rs" \
     && [[ -f "$PRAXIS_AI_DIR/filters/src/agentic/mcp/audit.rs" ]]; then
    ok "Build context verified: mod.rs has audit module, audit.rs present"
  else
    die "Build context missing audit code — patches may have failed"
  fi

  # Create BuildConfig if it doesn't exist
  if ! oc get buildconfig "$BC_NAME" -n "$PROJECT" &>/dev/null; then
    echo "  Creating BuildConfig $BC_NAME ..."
    oc new-build --name="$BC_NAME" \
      --strategy=docker \
      --binary=true \
      -n "$PROJECT" \
      --to="$BC_NAME:latest" 2>/dev/null

    # Set resource limits for Rust compilation
    oc patch buildconfig "$BC_NAME" -n "$PROJECT" --type=merge -p '{
      "spec": {
        "resources": {
          "requests": {"cpu":"2","memory":"4Gi"},
          "limits":   {"cpu":"4","memory":"8Gi"}
        }
      }
    }'
    ok "BuildConfig $BC_NAME created"
  else
    ok "BuildConfig $BC_NAME already exists"
  fi

  # Upload source and build on OCP
  echo "  Uploading source and starting build ..."
  echo "  (Rust compilation on OCP — takes ~11 min based on previous builds)"
  oc start-build "$BC_NAME" -n "$PROJECT" \
    --from-dir="$PRAXIS_AI_DIR" \
    --follow \
    --wait
  ok "Image build complete on OCP"
fi

# ── 5. Deploy on OCP ───────────────────────────────────────────────────────
step "Deploying Praxis on OCP"

# Ensure namespace exists
oc get ns "$PROJECT" &>/dev/null || oc new-project "$PROJECT"

# Detect the actual image stream tag from the BuildConfig output
IS_REF=$(oc get bc "$BC_NAME" -n "$PROJECT" -o jsonpath='{.spec.output.to.name}' 2>/dev/null || echo "$BC_NAME:latest")
IS_NAME="${IS_REF%%:*}"
IS_TAG="${IS_REF##*:}"
IMAGE="image-registry.openshift-image-registry.svc:5000/$PROJECT/$IS_NAME:$IS_TAG"
echo "  Image: $IMAGE"

if oc get deployment praxis-ai -n "$PROJECT" &>/dev/null; then
  oc set image deployment/praxis-ai "praxis-ai=$IMAGE" -n "$PROJECT"
  # Ensure new image is always pulled (tag doesn't change between builds)
  oc patch deployment praxis-ai -n "$PROJECT" -p \
    '{"spec":{"template":{"spec":{"containers":[{"name":"praxis-ai","imagePullPolicy":"Always"}]}}}}'
  oc rollout restart deployment/praxis-ai -n "$PROJECT"
else
  echo "  Creating Deployment praxis-ai ..."
  oc create deployment praxis-ai --image="$IMAGE" -n "$PROJECT"
  oc label deployment praxis-ai app=praxis-ai -n "$PROJECT"
  oc set resources deployment/praxis-ai \
    --requests=cpu=500m,memory=256Mi \
    --limits=cpu=2,memory=1Gi \
    -n "$PROJECT"
fi

oc rollout status deployment/praxis-ai -n "$PROJECT" --timeout=300s
ok "Praxis rollout complete"

# ── 6. Apply ClusterLogForwarder ─────────────────────────────────────────────
step "Applying ClusterLogForwarder (openshift-logging)"
if oc get ns openshift-logging &>/dev/null; then
  oc apply -f "$SCRIPT_DIR/deploy/cluster-log-forwarder.yaml"
  ok "ClusterLogForwarder applied"
else
  warn "openshift-logging namespace not found — skipping ClusterLogForwarder"
  warn "Install the OpenShift Logging operator first, then run:"
  warn "  oc apply -f deploy/cluster-log-forwarder.yaml"
fi

# ── 7. Apply Prometheus alerting rules ─────────────────────────────────────
step "Applying Prometheus alerting rules"
if [[ -f "$SCRIPT_DIR/deploy/prometheus-alerts.yaml" ]]; then
  oc apply -f "$SCRIPT_DIR/deploy/prometheus-alerts.yaml" -n "$PROJECT"
  ok "PrometheusRule 'praxis-mcp-alerts' applied (5 alert rules)"
  echo "  Alerts: McpExcessiveToolCalls, McpHighRejectionRate, McpToolCallErrorRate,"
  echo "          McpNoTraffic, McpHighToolLatency"
  echo "  View:   OCP Console → Observe → Alerting → filter 'mcp'"
else
  warn "deploy/prometheus-alerts.yaml not found — skipping"
fi

# ── 8. Run verification ─────────────────────────────────────────────────────
step "Running verification"

# If Logging + Loki are available and user didn't explicitly set SKIP_LOKI,
# enable Loki checks
if [[ "$SKIP_LOKI" != "0" ]] && oc get lokistack logging-loki -n openshift-logging &>/dev/null; then
  # Fire a test event and give the pipeline time to forward
  echo "  Loki detected — sending test event and waiting for pipeline..."
  curl -sk -X POST "https://$(oc get route praxis-ai -n "$PROJECT" -o jsonpath='{.spec.host}' 2>/dev/null)/mcp" \
    -H "Content-Type: application/json" \
    -H "x-tenant-id: loki-verify" \
    -d '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Chicago"}}}' \
    > /dev/null 2>&1 || true
  sleep 30
  SKIP_LOKI=0
  ok "Loki pipeline warm-up complete — enabling Loki verification"
fi

chmod +x "$SCRIPT_DIR/test/verify-audit-logs.sh"
PROJECT="$PROJECT" SKIP_LOKI="$SKIP_LOKI" bash "$SCRIPT_DIR/test/verify-audit-logs.sh"

# ── 9. Dashboard ───────────────────────────────────────────────────────────
step "Deploying MCP Audit Dashboard"
oc create configmap mcp-audit-dashboard \
  --from-file=index.html="$SCRIPT_DIR/dashboard/dashboard.html" \
  -n "$PROJECT" --dry-run=client -o yaml | oc apply -f -
ok "Dashboard ConfigMap created"

oc apply -f "$SCRIPT_DIR/deploy/dashboard.yaml" -n "$PROJECT"
oc rollout status deployment/mcp-audit-dashboard -n "$PROJECT" --timeout=60s 2>/dev/null || true

DASH_URL=$(oc get route mcp-audit-dashboard -n "$PROJECT" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$DASH_URL" ]]; then
  ok "Dashboard live at: https://$DASH_URL"
else
  warn "Dashboard deployed but route not yet ready"
fi

# ── 9b. Enable OCP Console log viewer (Observe → Logs) ─────────────────────
step "Enabling OCP Console log viewer"
if oc get lokistack logging-loki -n openshift-logging &>/dev/null; then
  # Try UIPlugin v1alpha1 first, then v1, then ConsolePlugin fallback
  UIPLUGIN_APPLIED=false

  if oc api-resources --api-group=observability.openshift.io 2>/dev/null | grep -q uiplugin; then
    # Detect the correct API version
    UIPLUGIN_VERSION=$(oc api-resources --api-group=observability.openshift.io 2>/dev/null \
      | grep uiplugin | awk '{print $NF}' | head -1)
    if [[ -n "$UIPLUGIN_VERSION" ]]; then
      cat <<EOF | oc apply -f - && UIPLUGIN_APPLIED=true
apiVersion: observability.openshift.io/${UIPLUGIN_VERSION}
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
EOF
    fi
  fi

  if [[ "$UIPLUGIN_APPLIED" == "true" ]]; then
    ok "UIPlugin 'logging' created — Observe → Logs available in OCP Console"
  else
    # Check if the logging ConsolePlugin already exists (some OCP versions use this instead)
    if oc get consoleplugin logging-view-plugin &>/dev/null 2>&1; then
      oc patch console.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"plugins":["logging-view-plugin"]}}' 2>/dev/null \
        && ok "ConsolePlugin 'logging-view-plugin' enabled" \
        || warn "Could not enable ConsolePlugin — enable manually in OCP Console settings"
    else
      warn "UIPlugin CRD not found on this cluster"
      warn "Observe → Logs may not be available — view logs via Grafana or oc CLI instead"
    fi
  fi
else
  warn "LokiStack not found — skipping console log viewer"
fi

# ── 9c. Raise LokiStack per-tenant query concurrency ───────────────────────
step "Tuning LokiStack query concurrency for dashboard use"
if oc get lokistack logging-loki -n openshift-logging &>/dev/null; then
  # Default maxConcurrentQueriesPerTenant is too low for Grafana dashboards
  # that fire multiple panel queries simultaneously — raise to 32
  oc patch lokistack logging-loki -n openshift-logging --type=merge -p '
    spec:
      limits:
        global:
          queries:
            maxConcurrentQueriesPerTenant: 32
  ' 2>/dev/null && ok "LokiStack query concurrency raised to 32" \
    || warn "Could not patch LokiStack — may need cluster-admin privileges"
else
  warn "LokiStack not found — skipping concurrency tuning"
fi

# ── 10. Grafana with Loki datasource and audit dashboard ────────────────────
step "Deploying Grafana with MCP Audit Dashboard"
if oc get lokistack logging-loki -n openshift-logging &>/dev/null; then

  # Deploy Grafana if not already present
  if ! oc get deployment grafana -n "$PROJECT" &>/dev/null; then
    echo "  Creating Grafana deployment ..."
    cat <<'GRAFANA_EOF' | oc apply -n "$PROJECT" -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana
  labels:
    app: grafana
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      serviceAccountName: grafana
      containers:
        - name: grafana
          image: docker.io/grafana/grafana:11.4.0
          ports:
            - containerPort: 3000
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: admin
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: praxis-audit
            - name: GF_AUTH_ANONYMOUS_ENABLED
              value: "true"
            - name: GF_AUTH_ANONYMOUS_ORG_ROLE
              value: Viewer
          volumeMounts:
            - name: grafana-storage
              mountPath: /var/lib/grafana
            - name: grafana-datasources
              mountPath: /etc/grafana/provisioning/datasources
              readOnly: true
            - name: grafana-dashboards-config
              mountPath: /etc/grafana/provisioning/dashboards
              readOnly: true
            - name: grafana-dashboards
              mountPath: /var/lib/grafana/dashboards
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: grafana-storage
          emptyDir: {}
        - name: grafana-datasources
          configMap:
            name: grafana-datasources
        - name: grafana-dashboards-config
          configMap:
            name: grafana-dashboards-config
        - name: grafana-dashboards
          configMap:
            name: grafana-dashboards
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  labels:
    app: grafana
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
      name: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
  labels:
    app: grafana
spec:
  to:
    kind: Service
    name: grafana
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
GRAFANA_EOF
    ok "Grafana Deployment, Service, Route created"
  else
    ok "Grafana deployment already exists"
  fi

  # Grant READ access to the collector SA (it already has WRITE from the CLF step)
  # OCP Logging 6.7 uses the loki.grafana.com API group for gateway authorization
  echo "  Granting Loki read access to collector SA ..."
  cat <<'LOKI_READER_EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: loki-application-reader
rules:
  - apiGroups: ["loki.grafana.com"]
    resources: ["application"]
    resourceNames: ["logs"]
    verbs: ["get"]
LOKI_READER_EOF
  ok "ClusterRole loki-application-reader created"

  if ! oc get clusterrolebinding mcp-audit-collector-loki-reader &>/dev/null; then
    oc create clusterrolebinding mcp-audit-collector-loki-reader \
      --clusterrole=loki-application-reader \
      --serviceaccount=openshift-logging:mcp-audit-collector
    ok "ClusterRoleBinding for Loki read access created"
  else
    ok "Loki read ClusterRoleBinding already exists"
  fi

  # Create a long-lived SA token for Loki access (now with both read + write)
  echo "  Creating Loki access token for Grafana ..."
  LOKI_TOKEN=$(oc create token mcp-audit-collector -n openshift-logging --duration=8760h 2>/dev/null || echo "")
  if [[ -z "$LOKI_TOKEN" ]]; then
    warn "Could not create token — Grafana datasource may need manual auth config"
    LOKI_TOKEN="REPLACE_ME"
  else
    ok "Loki access token created (valid 1 year, read+write)"
  fi

  # ConfigMap: Loki datasource provisioning
  cat <<EOF | oc apply -n "$PROJECT" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  labels:
    app: grafana
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: https://logging-loki-gateway-http.openshift-logging.svc:8080/api/logs/v1/application
        isDefault: true
        jsonData:
          httpHeaderName1: Authorization
          tlsSkipVerify: true
        secureJsonData:
          httpHeaderValue1: "Bearer ${LOKI_TOKEN}"
EOF
  ok "Loki datasource ConfigMap created"

  # ConfigMap: dashboard provisioning config
  cat <<'EOF' | oc apply -n "$PROJECT" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-config
  labels:
    app: grafana
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: praxis
        orgId: 1
        folder: Praxis
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 30
        options:
          path: /var/lib/grafana/dashboards
          foldersFromFilesStructure: false
EOF
  ok "Dashboard provisioning ConfigMap created"

  # ConfigMap: actual dashboard JSON
  oc create configmap grafana-dashboards \
    --from-file=praxis-mcp-audit.json="$SCRIPT_DIR/deploy/grafana-audit-dashboard.json" \
    -n "$PROJECT" --dry-run=client -o yaml | oc apply -f -
  ok "Audit dashboard JSON ConfigMap created"

  # Restart Grafana to pick up all ConfigMaps
  oc rollout restart deployment/grafana -n "$PROJECT" 2>/dev/null || true
  oc rollout status deployment/grafana -n "$PROJECT" --timeout=90s 2>/dev/null || true

  GRAFANA_URL=$(oc get route grafana -n "$PROJECT" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$GRAFANA_URL" ]]; then
    ok "Grafana live at: https://$GRAFANA_URL  (admin / praxis-audit)"
    ok "Audit dashboard: https://$GRAFANA_URL/d/praxis-mcp-audit"
  else
    warn "Grafana deployed but route not yet ready"
  fi
else
  warn "LokiStack not found — skipping Grafana deployment"
  warn "Install OpenShift Logging + LokiStack first, then re-run"
fi

# ── 11. Summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Praxis MCP Audit Logging — Install Complete ===${NC}"
echo ""
echo "  Audit events:  mcp.call.completed / rejected / initiated → pod stdout"
echo "  Log pipeline:  ClusterLogForwarder → LokiStack (openshift-logging)"
echo "  Alerts:        5 Prometheus alert rules (McpExcessiveToolCalls, etc.)"
[[ -n "${DASH_URL:-}" ]] && echo "  Dashboard:     https://$DASH_URL"
[[ -n "${GRAFANA_URL:-}" ]] && echo "  Grafana:       https://$GRAFANA_URL  (admin / praxis-audit)"
[[ -n "${GRAFANA_URL:-}" ]] && echo "  Audit board:   https://$GRAFANA_URL/d/praxis-mcp-audit"
echo ""
echo "  Re-run verification anytime:"
echo "    PROJECT=$PROJECT bash $SCRIPT_DIR/test/verify-audit-logs.sh"
