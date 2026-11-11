# Testing Praxis MCP Metrics Locally

## Prerequisites

- **Rust 1.96+**: `rustup install 1.96.0 && rustup default 1.96.0`
- **Python 3.8+**: for mock MCP server
- **git**: to clone praxis-proxy/ai
- **curl**: for traffic simulation

## Quick Start (3 terminals)

### Option A: Automated build

```bash
cd test-setup/
bash build-and-test.sh
```

This clones praxis-proxy/ai, writes `metrics.rs`, patches `mod.rs`, runs `cargo check`, runs unit tests, and builds the release binary. Then follow the 3-terminal instructions it prints.

### Option B: Manual steps

**Terminal 1 — Mock MCP server:**
```bash
python3 mock-mcp-server.py --port 3001 --error-rate 0.2 --latency-ms 100
```
This starts a fake MCP server that responds to `tools/list`, `tools/call`, and `server/discover`. The `--error-rate 0.2` makes 20% of tool calls fail (so you can verify the `status="error"` label works).

**Terminal 2 — Praxis proxy:**
```bash
# If you used build-and-test.sh:
./praxis-ai/target/release/praxis-ai -c praxis-test-config.yaml

# Or from container (won't have your patches — use for baseline comparison):
# docker run -p 8080:8080 -p 9902:9902 -v $(pwd)/praxis-test-config.yaml:/config.yaml \
#   ghcr.io/praxis-proxy/ai:latest -c /config.yaml
```

**Terminal 3 — Traffic simulation:**
```bash
bash simulate-traffic.sh
```

## What the simulation does

1. Preflight checks (Praxis health, metrics endpoint, mock server reachable)
2. Sends 7 MCP requests: 2x tools/list, 4x tools/call (different tools/cities), 1x server/discover
3. Sends 1 malformed request (missing header) to trigger rejection metrics
4. Fetches `/metrics` from port 9902 and checks for all 4 new metrics
5. Prints pass/fail summary

## Expected metrics output

After running the simulation, `curl http://127.0.0.1:9902/metrics | grep praxis_mcp_` should show:

```
praxis_mcp_requests_total{method="tools/call",protocol_version="2025-11-25"} 4
praxis_mcp_requests_total{method="tools/list",protocol_version="2025-11-25"} 2
praxis_mcp_requests_total{method="server/discover",protocol_version="2025-11-25"} 1
praxis_mcp_tool_calls_total{cluster="weather-mcp",status="ok",tool="weather_get_weather"} 3
praxis_mcp_tool_calls_total{cluster="weather-mcp",status="ok",tool="weather_forecast"} 1
praxis_mcp_tool_call_duration_seconds_bucket{cluster="weather-mcp",tool="weather_get_weather",le="0.25"} 3
praxis_mcp_filter_rejections_total{method="unknown",reason="missing_header"} 1
```

(Exact values depend on mock server error rate.)

## Testing on OCP

If you want to deploy on your OCP lab instead of locally:

1. Build a container image with the patches:
   ```bash
   cd praxis-ai/
   docker build -t quay.io/pmarhath/praxis-ai:mcp-metrics .
   docker push quay.io/pmarhath/praxis-ai:mcp-metrics
   ```

2. Deploy the mock MCP server as a pod (or use any real MCP server)

3. Create a ConfigMap from `praxis-test-config.yaml`, updating the endpoints to point to your mock server's Service

4. Deploy Praxis using your custom image with the ConfigMap mounted

5. Port-forward to the metrics port:
   ```bash
   oc port-forward svc/praxis-ai 9902:9902
   curl http://localhost:9902/metrics | grep praxis_mcp_
   ```

## Troubleshooting

**"unknown filter type: mcp"** — Build didn't include the MCP filter. Make sure you're building with `make release` (which uses the `full` feature set).

**No praxis_mcp_ metrics at all** — The patches weren't applied, or Praxis crashed on startup. Check `cargo check -p praxis-ai-filters` output and Praxis stderr.

**Metrics appear but values are 0** — The MCP filter isn't matching your requests. Check the `path: /mcp` in the config matches your curl path, and that `Mcp-Protocol-Version` and `Mcp-Method` headers are present.

**Connection refused on port 9902** — Add the `admin.metrics_address` config key. Without it, Praxis doesn't expose a metrics endpoint.
