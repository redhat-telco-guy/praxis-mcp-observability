#!/usr/bin/env bash
#
# check-metrics.sh — Verify MCP metrics are flowing through the full observability stack
#
# Checks: Praxis → ServiceMonitor → Prometheus → Grafana
#
set -uo pipefail

PROJECT="${PROJECT:-praxis-mcp-test}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}PASS${NC}"
FAIL="${RED}FAIL${NC}"
WARN="${YELLOW}WARN${NC}"

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  MCP Metrics Health Check"
echo "══════════════════════════════════════════════════════════"
echo "  Project: $PROJECT"
echo "  Time:    $(date)"
echo ""

# ──────────────────────────────────────────
# CHECK 1: Is Praxis pod running?
# ──────────────────────────────────────────
echo -e "${CYAN}[1/8]${NC} Praxis pod status"
PRAXIS_POD=$(oc -n "$PROJECT" get pods -l app=praxis-ai --no-headers 2>/dev/null | head -1)
if [[ -z "$PRAXIS_POD" ]]; then
    echo -e "  [$FAIL] No praxis-ai pod found in project $PROJECT"
    echo "  Fix: Deploy Praxis first with deploy-dashboard.sh"
    exit 1
else
    POD_NAME=$(echo "$PRAXIS_POD" | awk '{print $1}')
    POD_STATUS=$(echo "$PRAXIS_POD" | awk '{print $3}')
    POD_READY=$(echo "$PRAXIS_POD" | awk '{print $2}')
    if [[ "$POD_STATUS" == "Running" ]]; then
        echo -e "  [$PASS] $POD_NAME — $POD_STATUS ($POD_READY)"
    else
        echo -e "  [$FAIL] $POD_NAME — $POD_STATUS ($POD_READY)"
        echo "  Fix: Check logs: oc -n $PROJECT logs $POD_NAME"
    fi
fi
echo ""

# ──────────────────────────────────────────
# CHECK 2: Is Praxis /metrics endpoint responding?
# ──────────────────────────────────────────
echo -e "${CYAN}[2/8]${NC} Praxis /metrics endpoint (port 9902)"
METRICS_RAW=$(oc -n "$PROJECT" exec deploy/praxis-ai -- curl -s http://localhost:9902/metrics 2>/dev/null)
METRICS_EXIT=$?
if [[ $METRICS_EXIT -ne 0 || -z "$METRICS_RAW" ]]; then
    echo -e "  [$FAIL] Cannot reach http://localhost:9902/metrics inside the pod"
    echo "  Fix: Check Praxis config — metrics_address should be 0.0.0.0:9902"
    echo ""
else
    TOTAL_LINES=$(echo "$METRICS_RAW" | grep -v '^#' | grep -c '.' 2>/dev/null || echo 0)
    echo -e "  [$PASS] Endpoint responding — $TOTAL_LINES metric lines returned"
    echo ""

    # ──────────────────────────────────────────
    # CHECK 3: Are MCP metrics present?
    # ──────────────────────────────────────────
    echo -e "${CYAN}[3/8]${NC} MCP metrics in /metrics output"
    MCP_LINES=$(echo "$METRICS_RAW" | grep '^praxis_mcp_' | grep -v '^#')
    MCP_COUNT=$(echo "$MCP_LINES" | grep -c '.' 2>/dev/null || echo 0)

    if [[ "$MCP_COUNT" -gt 0 ]]; then
        echo -e "  [$PASS] Found $MCP_COUNT MCP metric lines"
        echo ""
        echo "  MCP metrics found:"
        echo "$MCP_LINES" | while read -r line; do
            NAME=$(echo "$line" | sed 's/{.*//' | sed 's/ .*//')
            VALUE=$(echo "$line" | awk '{print $NF}')
            echo -e "    ${GREEN}●${NC} $NAME = $VALUE"
        done
    else
        echo -e "  [$FAIL] No praxis_mcp_* metrics found in /metrics output"
        echo "  This means the MCP filter is not emitting metrics."
        echo "  Fix: Ensure the MCP filter is in your Praxis config and send some test traffic."
    fi
    echo ""

    # ──────────────────────────────────────────
    # CHECK 4: How many existing (non-MCP) metrics?
    # ──────────────────────────────────────────
    echo -e "${CYAN}[4/8]${NC} Existing Praxis metrics (non-MCP)"
    EXISTING_NAMES=$(echo "$METRICS_RAW" | grep -v '^#' | grep '.' | sed 's/{.*//' | sed 's/ .*//' | grep -v '^praxis_mcp_' | sort -u)
    EXISTING_COUNT=$(echo "$EXISTING_NAMES" | grep -c '.' 2>/dev/null || echo 0)
    echo -e "  [$PASS] $EXISTING_COUNT unique non-MCP metric names active on this cluster"
    echo ""
fi

# ──────────────────────────────────────────
# CHECK 5: ServiceMonitor deployed?
# ──────────────────────────────────────────
echo -e "${CYAN}[5/8]${NC} ServiceMonitor"
SM=$(oc -n "$PROJECT" get servicemonitor --no-headers 2>/dev/null)
if [[ -z "$SM" ]]; then
    echo -e "  [$FAIL] No ServiceMonitor found in $PROJECT"
    echo "  Fix: oc apply -f servicemonitor.yaml"
else
    echo "$SM" | while read -r line; do
        SM_NAME=$(echo "$line" | awk '{print $1}')
        echo -e "  [$PASS] ServiceMonitor: $SM_NAME"
    done
    # Check what port/path it targets
    SM_PORT=$(oc -n "$PROJECT" get servicemonitor -o jsonpath='{.items[0].spec.endpoints[0].port}' 2>/dev/null)
    SM_INTERVAL=$(oc -n "$PROJECT" get servicemonitor -o jsonpath='{.items[0].spec.endpoints[0].interval}' 2>/dev/null)
    SM_SELECTOR=$(oc -n "$PROJECT" get servicemonitor -o jsonpath='{.items[0].spec.selector.matchLabels}' 2>/dev/null)
    echo "  Port: ${SM_PORT:-unknown}  Interval: ${SM_INTERVAL:-unknown}  Selector: ${SM_SELECTOR:-unknown}"
fi
echo ""

# ──────────────────────────────────────────
# CHECK 6: User Workload Monitoring enabled?
# ──────────────────────────────────────────
echo -e "${CYAN}[6/8]${NC} User Workload Monitoring (required for Prometheus to scrape your metrics)"
UWM_PODS=$(oc -n openshift-user-workload-monitoring get pods --no-headers 2>/dev/null)
if [[ -z "$UWM_PODS" ]]; then
    echo -e "  [$FAIL] No pods in openshift-user-workload-monitoring namespace"
    echo ""
    echo -e "  ${BOLD}This is why Prometheus can't see your metrics!${NC}"
    echo "  User workload monitoring is NOT enabled on this cluster."
    echo ""
    echo "  Fix — run this (requires cluster-admin):"
    echo ""
    echo '  oc apply -f - <<EOF'
    echo '  apiVersion: v1'
    echo '  kind: ConfigMap'
    echo '  metadata:'
    echo '    name: cluster-monitoring-config'
    echo '    namespace: openshift-monitoring'
    echo '  data:'
    echo '    config.yaml: |'
    echo '      enableUserWorkload: true'
    echo '  EOF'
    echo ""
    echo "  Then wait ~60 seconds for pods to start."
else
    RUNNING=$(echo "$UWM_PODS" | grep -c "Running" || echo 0)
    TOTAL=$(echo "$UWM_PODS" | wc -l | tr -d ' ')
    if [[ "$RUNNING" -eq "$TOTAL" ]]; then
        echo -e "  [$PASS] $RUNNING/$TOTAL pods running"
    else
        echo -e "  [$WARN] $RUNNING/$TOTAL pods running (some not ready)"
    fi
    echo "$UWM_PODS" | while read -r line; do
        P_NAME=$(echo "$line" | awk '{print $1}')
        P_STATUS=$(echo "$line" | awk '{print $3}')
        P_READY=$(echo "$line" | awk '{print $2}')
        if [[ "$P_STATUS" == "Running" ]]; then
            echo -e "    ${GREEN}●${NC} $P_NAME ($P_READY)"
        else
            echo -e "    ${RED}●${NC} $P_NAME — $P_STATUS ($P_READY)"
        fi
    done
fi
echo ""

# ──────────────────────────────────────────
# CHECK 7: Can Prometheus query MCP metrics?
# ──────────────────────────────────────────
echo -e "${CYAN}[7/8]${NC} Prometheus query test (querying praxis_mcp_requests_total)"

PROM_RESULT=""
# Try user-workload prometheus first
PROM_RESULT=$(oc -n openshift-user-workload-monitoring exec sts/prometheus-user-workload -c prometheus -- \
    curl -s --data-urlencode 'query=praxis_mcp_requests_total' http://localhost:9090/api/v1/query 2>/dev/null)

if [[ -z "$PROM_RESULT" ]]; then
    # Fallback: try thanos-querier
    PROM_RESULT=$(oc -n openshift-monitoring exec deploy/thanos-querier -c thanos-query -- \
        curl -s --data-urlencode 'query=praxis_mcp_requests_total' http://localhost:9090/api/v1/query 2>/dev/null)
fi

if [[ -z "$PROM_RESULT" ]]; then
    echo -e "  [$FAIL] Cannot connect to Prometheus"
    echo "  This usually means user workload monitoring is not enabled (see check 6 above)"
else
    PROM_STATUS=$(echo "$PROM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "parse_error")
    RESULT_COUNT=$(echo "$PROM_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('result',[])))" 2>/dev/null || echo "0")

    if [[ "$PROM_STATUS" == "success" && "$RESULT_COUNT" -gt 0 ]]; then
        echo -e "  [$PASS] Prometheus returned $RESULT_COUNT result(s) for praxis_mcp_requests_total"
        echo ""
        echo "  Sample results:"
        echo "$PROM_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('data',{}).get('result',[])[:5]:
    labels = r.get('metric',{})
    val = r.get('value',['',''])[1]
    method = labels.get('method','?')
    server = labels.get('server','?')
    status = labels.get('status','?')
    print(f'    method={method}  server={server}  status={status}  value={val}')
" 2>/dev/null
    elif [[ "$PROM_STATUS" == "success" && "$RESULT_COUNT" -eq 0 ]]; then
        echo -e "  [$WARN] Prometheus query succeeded but returned 0 results"
        echo ""
        echo "  This means Prometheus CAN talk to Praxis but hasn't scraped any MCP data yet."
        echo "  Possible causes:"
        echo "    1. No MCP traffic sent yet → go to Test Lab and send some requests"
        echo "    2. ServiceMonitor selector doesn't match → check labels on praxis-ai Service"
        echo "    3. Scrape just started → wait 30s and re-run this script"
        echo ""
        echo "  Quick check — does Prometheus see the target at all?"
        TARGET_CHECK=$(oc -n openshift-user-workload-monitoring exec sts/prometheus-user-workload -c prometheus -- \
            curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data',{}).get('activeTargets',[]):
    if 'praxis' in t.get('labels',{}).get('job',''):
        health = t.get('health','?')
        endpoint = t.get('scrapeUrl','?')
        last_err = t.get('lastError','')
        print(f'    Target: {endpoint}')
        print(f'    Health: {health}')
        if last_err: print(f'    Error:  {last_err}')
" 2>/dev/null)
        if [[ -n "$TARGET_CHECK" ]]; then
            echo "$TARGET_CHECK"
        else
            echo "    Could not find a Prometheus target matching 'praxis'"
            echo "    The ServiceMonitor may not be matched. Check: oc -n $PROJECT get svc praxis-ai --show-labels"
        fi
    else
        echo -e "  [$FAIL] Prometheus query failed (status: $PROM_STATUS)"
        echo "  Raw response (first 200 chars): ${PROM_RESULT:0:200}"
    fi
fi
echo ""

# ──────────────────────────────────────────
# CHECK 8: Grafana
# ──────────────────────────────────────────
echo -e "${CYAN}[8/8]${NC} Grafana"
GRAFANA_PODS=$(oc get pods -A --no-headers 2>/dev/null | grep -i grafana)
if [[ -z "$GRAFANA_PODS" ]]; then
    echo -e "  [$WARN] No Grafana pods found on this cluster"
    echo "  Grafana is optional — you can use OCP Console → Observe → Metrics instead."
    echo "  If you want Grafana, install the Grafana Operator from OperatorHub."
else
    echo -e "  [$PASS] Grafana pods found:"
    echo "$GRAFANA_PODS" | while read -r line; do
        echo "    $line"
    done
fi

# Check if our dashboard ConfigMap exists
GRAFANA_CM=$(oc -n "$PROJECT" get configmap praxis-mcp-grafana --no-headers 2>/dev/null)
if [[ -n "$GRAFANA_CM" ]]; then
    echo -e "  [$PASS] Grafana dashboard ConfigMap 'praxis-mcp-grafana' exists"
else
    echo -e "  [$WARN] Grafana dashboard ConfigMap not found"
fi
echo ""

# ──────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────
echo "══════════════════════════════════════════════════════════"
echo -e "  ${BOLD}Summary${NC}"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Flow: Praxis → ServiceMonitor → Prometheus → Grafana"
echo ""

# Recompute pass/fail for summary
HAS_POD="no"; [[ -n "$PRAXIS_POD" && "$(echo "$PRAXIS_POD" | awk '{print $3}')" == "Running" ]] && HAS_POD="yes"
HAS_METRICS="no"; [[ -n "$METRICS_RAW" ]] && HAS_METRICS="yes"
HAS_MCP="no"; [[ "${MCP_COUNT:-0}" -gt 0 ]] && HAS_MCP="yes"
HAS_SM="no"; [[ -n "$SM" ]] && HAS_SM="yes"
HAS_UWM="no"; [[ -n "$UWM_PODS" ]] && HAS_UWM="yes"
HAS_PROM="no"; [[ "${PROM_STATUS:-}" == "success" && "${RESULT_COUNT:-0}" -gt 0 ]] && HAS_PROM="yes"

icon() { [[ "$1" == "yes" ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"; }

echo -e "  $(icon $HAS_POD)  Praxis pod running"
echo -e "  $(icon $HAS_METRICS)  /metrics endpoint responding"
echo -e "  $(icon $HAS_MCP)  MCP metrics being emitted (praxis_mcp_*)"
echo -e "  $(icon $HAS_SM)  ServiceMonitor deployed"
echo -e "  $(icon $HAS_UWM)  User Workload Monitoring enabled"
echo -e "  $(icon $HAS_PROM)  Prometheus can query MCP metrics"
echo ""

if [[ "$HAS_PROM" == "yes" ]]; then
    echo -e "  ${GREEN}${BOLD}All clear!${NC} MCP metrics are flowing end-to-end."
    echo "  You can now open OCP Console → Observe → Metrics → type praxis_mcp"
elif [[ "$HAS_MCP" == "yes" && "$HAS_UWM" == "no" ]]; then
    echo -e "  ${YELLOW}${BOLD}Almost there!${NC} Praxis is emitting MCP metrics but Prometheus can't see them."
    echo -e "  ${BOLD}Action needed:${NC} Enable User Workload Monitoring (see check 6 above)."
elif [[ "$HAS_MCP" == "yes" && "$HAS_UWM" == "yes" ]]; then
    echo -e "  ${YELLOW}${BOLD}Almost there!${NC} Metrics exist and Prometheus is running, but query returned 0 results."
    echo -e "  ${BOLD}Action:${NC} Send some traffic from Test Lab, wait 30s, re-run this script."
elif [[ "$HAS_METRICS" == "yes" && "$HAS_MCP" == "no" ]]; then
    echo -e "  ${RED}${BOLD}MCP metrics not found!${NC} Praxis is running but the MCP filter isn't emitting metrics."
    echo -e "  ${BOLD}Action:${NC} Check your Praxis config has the MCP filter enabled, and send some MCP traffic."
else
    echo -e "  ${RED}${BOLD}Praxis is not healthy.${NC} Fix the pod first before checking metrics."
fi
echo ""
echo "══════════════════════════════════════════════════════════"
