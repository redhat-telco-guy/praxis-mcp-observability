#!/bin/bash
# ══════════════════════════════════════════════════════════════
# build-on-ocp.sh — Build Praxis with MCP metrics on OpenShift
# ══════════════════════════════════════════════════════════════
#
# This builds the Praxis container image entirely on the OCP cluster.
# No local Rust toolchain needed — everything compiles inside the build pod.
#
# What it does:
#   1. Creates an ImageStream (praxis-ai:mcp-metrics)
#   2. Creates a binary Docker BuildConfig
#   3. Uploads Containerfile + metrics.rs + patch-mod-rs.py as build context
#   4. Waits for the build to complete (~12-15 minutes)
#
# Prerequisites:
#   - oc CLI logged in to your OCP cluster
#   - A project/namespace to build in (default: praxis-mcp-test)
#
# Usage:
#   bash build-on-ocp.sh                    # uses default namespace
#   bash build-on-ocp.sh my-namespace       # specify namespace
#
set -euo pipefail

NAMESPACE="${1:-praxis-mcp-test}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find files — handle running from repo root or build/ subdirectory
if [ -f "$SCRIPT_DIR/src/metrics.rs" ]; then
    # Running from repo root
    METRICS_RS="$SCRIPT_DIR/src/metrics.rs"
    PATCH_PY="$SCRIPT_DIR/src/patch-mod-rs.py"
    CONTAINERFILE="$SCRIPT_DIR/build/Containerfile"
elif [ -f "$SCRIPT_DIR/../src/metrics.rs" ]; then
    # Running from build/ subdirectory
    METRICS_RS="$SCRIPT_DIR/../src/metrics.rs"
    PATCH_PY="$SCRIPT_DIR/../src/patch-mod-rs.py"
    CONTAINERFILE="$SCRIPT_DIR/Containerfile"
else
    echo "ERROR: Cannot find src/metrics.rs. Run from the repo root or build/ directory."
    exit 1
fi

echo "══════════════════════════════════════════════════"
echo "  Building Praxis + MCP Metrics on OCP"
echo "══════════════════════════════════════════════════"
echo ""
echo "  Namespace:     $NAMESPACE"
echo "  Containerfile: $CONTAINERFILE"
echo "  metrics.rs:    $METRICS_RS"
echo "  patch script:  $PATCH_PY"
echo ""

# Ensure namespace exists
oc get namespace "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE"
oc project "$NAMESPACE"

# ── Step 1: ImageStream ──
echo "[1/4] Creating ImageStream..."
oc get imagestream praxis-ai -n "$NAMESPACE" 2>/dev/null || \
    oc create imagestream praxis-ai -n "$NAMESPACE"
echo "  ImageStream: praxis-ai"

# ── Step 2: Build context ──
echo ""
echo "[2/4] Preparing build context..."
BUILD_CTX=$(mktemp -d)
cp "$CONTAINERFILE" "$BUILD_CTX/Dockerfile"
cp "$METRICS_RS" "$BUILD_CTX/metrics.rs"
cp "$PATCH_PY" "$BUILD_CTX/patch-mod-rs.py"
echo "  Build context: $BUILD_CTX"
ls -la "$BUILD_CTX/"

# ── Step 3: BuildConfig ──
echo ""
echo "[3/4] Creating BuildConfig..."
oc delete buildconfig praxis-ai-mcp-metrics -n "$NAMESPACE" 2>/dev/null || true

oc new-build \
    --name=praxis-ai-mcp-metrics \
    --binary \
    --strategy=docker \
    --to=praxis-ai:mcp-metrics \
    -n "$NAMESPACE" \
    2>/dev/null || true
echo "  BuildConfig: praxis-ai-mcp-metrics"

# ── Step 4: Build ──
echo ""
echo "[4/4] Starting build (compiling Rust on-cluster — takes ~12-15 min)..."
echo "  Uploading: Dockerfile + metrics.rs + patch-mod-rs.py"
echo ""

oc start-build praxis-ai-mcp-metrics \
    --from-dir="$BUILD_CTX" \
    --follow \
    -n "$NAMESPACE"

# Clean up
rm -rf "$BUILD_CTX"

# Check result
BUILD_STATUS=$(oc get build -l buildconfig=praxis-ai-mcp-metrics \
    -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].status.phase}')

echo ""
if [[ "$BUILD_STATUS" == "Complete" ]]; then
    IMAGE="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/praxis-ai:mcp-metrics"
    echo "══════════════════════════════════════════════════"
    echo "  BUILD SUCCESSFUL"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "  Image: $IMAGE"
    echo ""
    echo "  Next steps:"
    echo "    1. Run: bash deploy/deploy-all.sh"
    echo "       (or bash deploy-all.sh depending on your location)"
    echo ""
    echo "    2. Or deploy manually:"
    echo "       oc create deployment praxis-ai --image=$IMAGE"
    echo ""
else
    echo "══════════════════════════════════════════════════"
    echo "  BUILD FAILED (status: $BUILD_STATUS)"
    echo "══════════════════════════════════════════════════"
    echo ""
    LATEST=$(oc get builds -l buildconfig=praxis-ai-mcp-metrics \
        -n "$NAMESPACE" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}')
    echo "  Check logs: oc -n $NAMESPACE logs build/$LATEST"
    exit 1
fi
