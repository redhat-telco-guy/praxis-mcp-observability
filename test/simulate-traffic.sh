#!/usr/bin/env bash
#
# simulate-traffic.sh — Send MCP traffic through Praxis and verify metrics.
#
# Prerequisites:
#   - mock-mcp-server.py running on port 3001
#   - Praxis running with praxis-test-config.yaml on port 8080
#   - Metrics endpoint on port 9902
#
# Usage:
#   bash simulate-traffic.sh
#
set -euo pipefail

PRAXIS="http://127.0.0.1:8080"
METRICS="http://127.0.0.1:9902/metrics"
MCP_PATH="/mcp"
PASS=0
FAIL=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

send_mcp() {
    local method="$1"
    local params="$2"
    local desc="$3"

    echo -n "  Sending $desc... "
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$PRAXIS$MCP_PATH" \
        -H "Content-Type: application/json" \
        -H "Mcp-Protocol-Version: 2025-11-25" \
        -H "Mcp-Method: $method" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        2>&1)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}OK${NC} (HTTP $http_code)"
        return 0
    else
        echo -e "${RED}FAIL${NC} (HTTP $http_code)"
        echo "    Response: $body"
        return 1
    fi
}

check_metric() {
    local metric_name="$1"
    local expected_label="$2"
    local desc="$3"

    echo -n "  Checking $desc... "
    local metrics_output
    metrics_output=$(curl -s "$METRICS" 2>&1)

    if echo "$metrics_output" | grep -q "$metric_name"; then
        local matching_lines
        matching_lines=$(echo "$metrics_output" | grep "$metric_name" | head -5)
        echo -e "${GREEN}FOUND${NC}"
        echo "$matching_lines" | while IFS= read -r line; do
            echo "    $line"
        done
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}NOT FOUND${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo "=========================================="
echo "  MCP Metrics Traffic Simulation"
echo "=========================================="
echo ""

# ── Preflight checks ──
echo "── Preflight checks ──"
echo -n "  Praxis health check... "
if curl -s "$PRAXIS/" | grep -q "ok"; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAIL${NC} — Is Praxis running on port 8080?"
    exit 1
fi

echo -n "  Metrics endpoint... "
if curl -s "$METRICS" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAIL${NC} — Is metrics endpoint on port 9902?"
    exit 1
fi

echo -n "  Mock MCP server... "
if curl -s -X POST "http://127.0.0.1:3001/mcp" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | grep -q "tools"; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAIL${NC} — Is mock-mcp-server.py running on port 3001?"
    exit 1
fi
echo ""

# ── Phase 1: Baseline metrics ──
echo "── Phase 1: Baseline metrics (before traffic) ──"
echo -n "  Fetching baseline... "
BASELINE=$(curl -s "$METRICS" 2>&1)
if echo "$BASELINE" | grep -q "praxis_mcp_"; then
    echo -e "${YELLOW}MCP metrics already present (previous test run?)${NC}"
else
    echo -e "${GREEN}Clean baseline — no MCP metrics yet${NC}"
fi
echo ""

# ── Phase 2: Send MCP traffic ──
echo "── Phase 2: Sending MCP traffic ──"

# tools/list requests
send_mcp "tools/list" '{}' "tools/list #1"
send_mcp "tools/list" '{}' "tools/list #2"

# tools/call requests (weather tools — note the tool_prefix stripping)
send_mcp "tools/call" '{"name":"weather_get_weather","arguments":{"city":"Austin"}}' \
    "tools/call weather_get_weather (Austin)"
send_mcp "tools/call" '{"name":"weather_get_weather","arguments":{"city":"Prague"}}' \
    "tools/call weather_get_weather (Prague)"
send_mcp "tools/call" '{"name":"weather_get_weather","arguments":{"city":"Delhi"}}' \
    "tools/call weather_get_weather (Delhi)"
send_mcp "tools/call" '{"name":"weather_forecast","arguments":{"city":"Austin","days":5}}' \
    "tools/call weather_forecast (Austin)"

# server/discover
send_mcp "server/discover" '{}' "server/discover"

# Send a malformed request (missing required header) to trigger rejection
echo -n "  Sending malformed request (no Mcp-Method header)... "
MALFORMED=$(curl -s -w "\n%{http_code}" \
    -X POST "$PRAXIS$MCP_PATH" \
    -H "Content-Type: application/json" \
    -H "Mcp-Protocol-Version: 2025-11-25" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"weather_get_weather"}}' \
    2>&1)
MALFORMED_CODE=$(echo "$MALFORMED" | tail -1)
echo -e "${YELLOW}HTTP $MALFORMED_CODE${NC} (rejection expected)"

echo ""
sleep 1  # Let metrics settle

# ── Phase 3: Verify metrics ──
echo "── Phase 3: Verifying Prometheus metrics ──"
echo ""

echo -e "${YELLOW}  Full MCP metrics output:${NC}"
echo "  ────────────────────────────────"
curl -s "$METRICS" 2>&1 | grep "praxis_mcp_" | while IFS= read -r line; do
    echo "  $line"
done
echo "  ────────────────────────────────"
echo ""

# Check each metric
echo "  Metric checks:"

check_metric "praxis_mcp_requests_total" "method" \
    "praxis_mcp_requests_total (request counter)" || true

check_metric "praxis_mcp_tool_calls_total" "tool" \
    "praxis_mcp_tool_calls_total (tool call counter)" || true

check_metric "praxis_mcp_tool_call_duration_seconds" "tool" \
    "praxis_mcp_tool_call_duration_seconds (latency histogram)" || true

check_metric "praxis_mcp_filter_rejections_total" "reason" \
    "praxis_mcp_filter_rejections_total (rejection counter)" || true

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}All MCP metrics are working! Ready to file the PR.${NC}"
else
    echo -e "  ${RED}Some metrics are missing. Check the output above.${NC}"
    echo ""
    echo "  Debugging tips:"
    echo "    1. Check Praxis logs for errors"
    echo "    2. Verify the MCP filter is loaded: curl -s $PRAXIS/ "
    echo "    3. Full metrics dump: curl -s $METRICS | grep praxis_"
    echo "    4. Make sure the patches compiled correctly (cargo check)"
fi

echo ""
echo "── Useful PromQL queries for Grafana ──"
echo '  rate(praxis_mcp_requests_total[5m])                    # Request rate by method'
echo '  rate(praxis_mcp_tool_calls_total{status="error"}[5m])  # Error rate'
echo '  histogram_quantile(0.99, rate(praxis_mcp_tool_call_duration_seconds_bucket[5m]))  # p99 latency'
echo '  topk(10, rate(praxis_mcp_tool_calls_total[5m]))        # Top tools by call rate'
