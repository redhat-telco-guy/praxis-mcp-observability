#!/usr/bin/env bash
#
# push-to-fork.sh
#
# Pushes MCP metrics to your fork of praxis-proxy/ai.
#
# What it does:
#   1. Checks out a clean branch from upstream main
#   2. Copies metrics.rs into the MCP filter directory
#   3. Runs patch-mod-rs.py to integrate metrics into mod.rs
#   4. Runs cargo check to verify compilation
#   5. Commits and pushes to your fork
#
# Prerequisites:
#   - Fork of praxis-proxy/ai cloned locally
#   - gh CLI authenticated (or git push access to your fork)
#   - Rust toolchain installed (cargo)
#   - Python 3 installed (for the patcher)
#
# Usage:
#   export REPO_DIR=$HOME/src/praxis-ai    # Path to your clone
#   export FORK_REMOTE=origin               # Your fork's remote name
#   bash push-to-fork.sh
#
set -euo pipefail

BRANCH="feat/mcp-protocol-metrics"
FORK_REMOTE="${FORK_REMOTE:-origin}"
REPO_DIR="${REPO_DIR:-$HOME/src/praxis-ai}"
MCP_PKG="filters/src/agentic/mcp"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find the src/ directory (could be run from upstream-pr/ or repo root)
if [ -f "$SCRIPT_DIR/../src/metrics.rs" ]; then
    SRC_DIR="$SCRIPT_DIR/../src"
elif [ -f "$SCRIPT_DIR/src/metrics.rs" ]; then
    SRC_DIR="$SCRIPT_DIR/src"
else
    echo "ERROR: Cannot find src/metrics.rs relative to this script."
    echo "Make sure you're running from the praxis-mcp-observability repo."
    exit 1
fi

echo "=== Pushing MCP Metrics to Fork ==="
echo "  Repo:    $REPO_DIR"
echo "  Branch:  $BRANCH"
echo "  Remote:  $FORK_REMOTE"
echo "  Source:  $SRC_DIR"
echo ""

cd "$REPO_DIR"

# ── Step 1: Clean branch from upstream main ──
echo "[1/5] Creating clean branch from upstream main..."
git fetch origin main 2>/dev/null || git fetch upstream main 2>/dev/null
git checkout -B "$BRANCH" FETCH_HEAD
echo "  Branch: $BRANCH"

# ── Step 2: Copy metrics.rs ──
echo ""
echo "[2/5] Copying metrics.rs..."
cp "$SRC_DIR/metrics.rs" "$MCP_PKG/metrics.rs"
echo "  Copied to $MCP_PKG/metrics.rs"

# ── Step 3: Patch mod.rs ──
echo ""
echo "[3/5] Patching mod.rs..."
python3 "$SRC_DIR/patch-mod-rs.py"
echo "  mod.rs patched"

# ── Step 4: Verify compilation ──
echo ""
echo "[4/5] Running cargo check (this takes a few minutes)..."
cargo check --package praxis-ai-filters 2>&1 | tail -5
echo "  Compilation check passed"

# ── Step 5: Commit and push ──
echo ""
echo "[5/5] Committing and pushing..."
git add "$MCP_PKG/metrics.rs" "$MCP_PKG/mod.rs"
git commit -s -m "feat(mcp): add per-tool Prometheus metrics for MCP traffic

Add four new Prometheus metrics to the MCP filter, closing the
observability gap for MCP tool-call traffic routed through Praxis.

New metrics:
  - praxis_mcp_requests_total{method, protocol_version}
  - praxis_mcp_tool_calls_total{tool, cluster, status}
  - praxis_mcp_tool_call_duration_seconds{tool, cluster}
  - praxis_mcp_filter_rejections_total{method, reason}

Design decisions:
  - Tool-name cardinality bounded via ArcSwap<HashSet<String>>,
    cap of 512 distinct values, overflow → \"other\"
  - Cross-phase timing uses nanos-since-epoch in HttpFilterContext
    metadata (no per-request heap allocation)
  - Rejection reasons are a closed set: invalid_params,
    header_mismatch, missing_header, invalid_jsonrpc
  - All label vocabularies are bounded — safe for high-cardinality
    Prometheus deployments
  - Follows existing patterns from llm_metrics.rs

Testing:
  - 5 unit tests (counter emission, histogram recording,
    rejection labels, cardinality bounding, concurrent admission)
  - Deployed on OCP 4.22 with 3 mock MCP backends,
    verified end-to-end with Prometheus scraping

Signed-off-by: Puneet Marhatha <pmarhath@redhat.com>"

git push "$FORK_REMOTE" "$BRANCH" --force-with-lease

echo ""
echo "=== Done! ==="
echo ""
echo "Open the PR at:"
echo "  https://github.com/praxis-proxy/ai/compare/main...${GH_USER:-redhat-telco-guy}:${BRANCH}"
echo ""
echo "Use upstream-pr/PR_DESCRIPTION.md as the PR body."
