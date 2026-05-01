#!/usr/bin/env bash
#
# Run every scenario in $CONFIG (default matrix.yaml) in parallel, each in
# its own kind cluster. Per-scenario log: /tmp/matrix-<label>.log. Summary:
# out/runs/INDEX.tsv.
#
# Override with CONFIG=<path> ./matrix.sh to run a subset (e.g. matrix-istio.yaml).
# Compatible with bash 3.2 (macOS default): no mapfile, no `wait -n`.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-matrix.yaml}"
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required (brew install yq, or https://github.com/mikefarah/yq)" >&2
  exit 1
fi
echo "==> using config: $CONFIG"

# Parse $CONFIG into "<label>\t<KEY=VAL KEY=VAL ...>" lines.
SCENARIOS=()
while IFS= read -r line; do
  [ -n "$line" ] && SCENARIOS+=("$line")
done < <(yq '.scenarios[] | [.label, (.env | to_entries | map("\(.key)=\(.value)") | join(" "))] | @tsv' "$CONFIG")

if [ "${#SCENARIOS[@]}" -eq 0 ]; then
  echo "ERROR: no scenarios parsed from matrix.yaml" >&2
  exit 1
fi

echo "==> pre-building images so concurrent runs hit warm cache"
docker build -q -t ztunnel-rst-repro:local .                 >/dev/null &
docker build -q -t ztunnel-rst-repro-server:local app/server >/dev/null &
docker build -q -t ztunnel-rst-repro-client:local app/client >/dev/null &
wait

# Pre-pull istio images on the host once. Each kind cluster's istioctl
# install would otherwise pull these from Docker Hub fresh, and parallel
# matrix runs (8+ scenarios x 4 images) blow past Docker Hub's 100-pulls-
# per-6-hours unauthenticated rate limit. Pulling once on the host and
# loading via `kind load docker-image` into each cluster (in reproduce.sh)
# avoids the limit entirely after the first matrix run.
#
# ISTIO_VERSION must match Dockerfile's ARG ISTIO_VERSION (currently 1.29.2).
ISTIO_VERSION="1.29.2"
ISTIO_IMAGES=(
  "docker.io/istio/pilot:${ISTIO_VERSION}-distroless"
  "docker.io/istio/proxyv2:${ISTIO_VERSION}-distroless"
  "docker.io/istio/install-cni:${ISTIO_VERSION}-distroless"
  "docker.io/istio/ztunnel:${ISTIO_VERSION}-distroless"
)
echo "==> pre-pulling istio images (avoids Docker Hub rate-limit on parallel runs)"
# Best-effort: a failure here (rate limit, transient network) is non-fatal.
for img in "${ISTIO_IMAGES[@]}"; do
  ( docker pull -q "$img" >/dev/null 2>&1 || \
    echo "    warning: pre-pull failed for $img (will fall back to per-cluster pull)" ) &
done
wait

# Export each image to a single tarball under out/.istio-tarballs/ so
# parallel scenarios can `kind load image-archive` from a shared file
# instead of running concurrent `docker save` operations that race on the
# host docker daemon. Also sidesteps a multi-arch quirk: `docker save`
# emits a manifest list referencing both linux/amd64 and linux/arm64
# manifests, but only the local-platform layers, which makes ctr import
# fail with "content digest not found" on the missing-platform manifest.
TARBALL_DIR="out/.istio-tarballs"
mkdir -p "$TARBALL_DIR"
echo "==> exporting istio images to shared tarballs (one-time per matrix run)"
exported_tarballs=()
for img in "${ISTIO_IMAGES[@]}"; do
  base="${img##*/}"; base="${base%%:*}"   # e.g. docker.io/istio/pilot:... -> pilot
  tarball="$TARBALL_DIR/${base}.tar"
  if docker image inspect "$img" >/dev/null 2>&1; then
    if docker save "$img" -o "$tarball" 2>/dev/null; then
      exported_tarballs+=("$tarball")
    else
      echo "    warning: docker save failed for $img"
    fi
  fi
done

# `docker save` emits an OCI tarball whose manifest list references all
# platforms (amd64 + arm64) but only ships local-platform layers. `kind
# load image-archive` then fails on the foreign-platform manifest digest.
# Strip foreign-platform entries so the tarball is self-consistent.
if [ "${#exported_tarballs[@]}" -gt 0 ]; then
  echo "==> stripping foreign-platform manifests from istio tarballs"
  python3 scripts/_strip_foreign_arch.py "${exported_tarballs[@]}"
fi
export ISTIO_VERSION

# Wipe any kind clusters left over from previous runs. Each matrix scenario
# uses a unique CLUSTER name so leftovers don't collide -- but they DO eat
# Docker memory and starve the new clusters' apiservers, which cascades into
# istioctl install timeouts. Always start clean.
echo "==> cleaning up any leftover kind clusters"
./scripts/cleanup.sh --all

run_one() {
  local label="$1" env_str="$2"
  local cluster="ztunnel-rst-repro-${label}"
  local log="/tmp/matrix-${label}.log"
  echo "==== [$(date +%H:%M:%S)] start $label (env: ${env_str:-none}) ===="
  SKIP_BUILD=1 CLUSTER="$cluster" MATRIX_LABEL="$label" env $env_str \
    CLUSTER="$cluster" SKIP_BUILD=1 MATRIX_LABEL="$label" \
    ./run.sh > "$log" 2>&1
  local rc=$?
  # Always tear down this scenario's kind cluster so the next batch doesn't
  # inherit its memory footprint. The pcap, client.log, events.log, and
  # report.txt are already on the host volume under out/runs/ -- the cluster
  # itself isn't needed past this point.
  CLUSTER="$cluster" ./scripts/cleanup.sh >> "$log" 2>&1 || true
  echo "==== [$(date +%H:%M:%S)] done  $label exit=$rc ===="
}

# Run in fixed-size batches: spawn MAX_PARALLEL, wait for them all, repeat.
# Slightly less efficient than pipelined `wait -n` (next batch waits for the
# slowest of the current batch), but works in bash 3.2.
MAX_PARALLEL="${MAX_PARALLEL:-6}"
echo "==> running ${#SCENARIOS[@]} scenarios, $MAX_PARALLEL at a time"
total=${#SCENARIOS[@]}
i=0
while [ "$i" -lt "$total" ]; do
  batch_end=$((i + MAX_PARALLEL))
  [ "$batch_end" -gt "$total" ] && batch_end=$total
  for ((j=i; j<batch_end; j++)); do
    s="${SCENARIOS[$j]}"
    run_one "${s%%$'\t'*}" "${s#*$'\t'}" &
  done
  wait
  i=$batch_end
done

echo
echo "==== ALL DONE ===="
( head -1 out/runs/INDEX.tsv; tail -n +2 out/runs/INDEX.tsv | sort -k1 )
