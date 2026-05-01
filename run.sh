#!/usr/bin/env bash
#
# One-shot wrapper for the ambient + node-consolidation reproduction.
# Builds the orchestrator + Node.js app images on the host, then runs
# the orchestrator container which drives the kind cluster end to end.
#
# Outputs land in ./out:
#   ztunnel.pcap  -- pcap from inside the client pod's netns
#   client.log    -- Node http.Agent client per-request log
#   summary.txt   -- annotated notes on what to look for
#
# Requires only Docker on the host. See README.md for context.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is required and must be running."
  echo "  macOS:    brew install --cask docker  (then open Docker Desktop)"
  echo "  Linux:    https://docs.docker.com/engine/install/"
  exit 1
fi

mkdir -p out

# Find the host's Docker socket. macOS Docker Desktop and Linux differ on path.
SOCK="${DOCKER_HOST:-}"
if [ -z "$SOCK" ]; then
  for candidate in /var/run/docker.sock "$HOME/.docker/run/docker.sock" "$HOME/.colima/default/docker.sock"; do
    [ -S "$candidate" ] && SOCK="unix://$candidate" && break
  done
fi
[ -z "$SOCK" ] && SOCK="unix:///var/run/docker.sock"
SOCK_PATH="${SOCK#unix://}"

# SKIP_BUILD=1 lets matrix.sh pre-build all three images once and have each
# parallel run.sh skip them, instead of having every run.sh racing for the
# build cache lock and producing redundant log lines.
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> building reproducer image (cached on subsequent runs)"
  docker build -q -t ztunnel-rst-repro:local . >/dev/null

  echo "==> building Node.js server image"
  docker build -q -t ztunnel-rst-repro-server:local app/server >/dev/null

  echo "==> building Node.js client image (with tcpdump)"
  docker build -q -t ztunnel-rst-repro-client:local app/client >/dev/null
fi

echo "==> running reproducer (bakes kind cluster, captures pcap)"
docker run --rm \
  -v "$SOCK_PATH:/var/run/docker.sock" \
  -v "$(pwd)/out:/out" \
  --network host \
  -e WAYPOINT_ENABLED="${WAYPOINT_ENABLED:-}" \
  -e WITHOUT_ISTIO="${WITHOUT_ISTIO:-}" \
  -e CLIENT_FIX="${CLIENT_FIX:-}" \
  -e CLUSTER="${CLUSTER:-ztunnel-rst-repro}" \
  -e EVENTS="${EVENTS:-}" \
  -e MATRIX_LABEL="${MATRIX_LABEL:-}" \
  -e ISTIO_VERSION="${ISTIO_VERSION:-}" \
  ztunnel-rst-repro:local

echo
echo "Done. Capture: $(pwd)/out/ztunnel.pcap"
echo "Notes:        $(pwd)/out/summary.txt"
echo
echo "Open the pcap in Wireshark, filter:  tcp.flags.reset == 1"
