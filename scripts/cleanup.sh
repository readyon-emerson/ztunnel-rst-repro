#!/usr/bin/env bash
#
# Tears down kind clusters created by ./run.sh or ./matrix.sh. Uses kind from
# inside the repro image so the host doesn't need kind installed.
#
#   ./scripts/cleanup.sh              -- delete just $CLUSTER (default: ztunnel-rst-repro)
#   ./scripts/cleanup.sh --all        -- delete every kind cluster whose name starts with
#                                        ztunnel-rst-repro (matrix runs leave one per scenario)
set -euo pipefail

MODE="single"
if [ "${1:-}" = "--all" ]; then
  MODE="all"
fi

# kind on the host if available, otherwise via the orchestrator image (which
# bakes kind in). Either path needs the daemon socket; the docker fallback
# also needs to know where it lives.
have_kind=0
if command -v kind >/dev/null 2>&1; then
  have_kind=1
fi

SOCK="${DOCKER_HOST:-}"
if [ -z "$SOCK" ]; then
  for c in /var/run/docker.sock "$HOME/.docker/run/docker.sock" "$HOME/.colima/default/docker.sock"; do
    [ -S "$c" ] && SOCK="unix://$c" && break
  done
fi
SOCK_PATH="${SOCK#unix://}"

run_kind() {
  if [ "$have_kind" -eq 1 ]; then
    kind "$@"
  else
    docker run --rm --network host \
      -v "$SOCK_PATH:/var/run/docker.sock" \
      --entrypoint kind ztunnel-rst-repro:local "$@"
  fi
}

if [ "$MODE" = "all" ]; then
  echo "==> listing kind clusters"
  clusters=$(run_kind get clusters 2>/dev/null | grep -E '^ztunnel-rst-repro' || true)
  if [ -z "$clusters" ]; then
    echo "    no ztunnel-rst-repro-* clusters found"
    exit 0
  fi
  for c in $clusters; do
    echo "==> deleting '$c'"
    run_kind delete cluster --name "$c" || true
  done
else
  CLUSTER="${CLUSTER:-ztunnel-rst-repro}"
  echo "==> deleting kind cluster '$CLUSTER'"
  run_kind delete cluster --name "$CLUSTER"
fi
