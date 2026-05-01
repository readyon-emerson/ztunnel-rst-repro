#!/usr/bin/env bash
#
# Walks a kind cluster through the Karpenter-consolidation-with-GNS sequence
# in Istio ambient mode and captures what the client app sees:
#   * out/<run>/client.log    -- Node client per-request log (ECONNRESET, etc.)
#   * out/<run>/ztunnel.pcap  -- wire-level pcap from inside the client pod's
#                                netns (FINs, RSTs, HBONE traffic on :15008)
#   * out/<run>/events.log    -- when each disruption fired
#   * out/<run>/report.txt    -- generated summary
#
# See ../README.md for the conclusion this repo demonstrates.
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

CLUSTER="${CLUSTER:-ztunnel-rst-repro}"
NS="${NS:-rsttest}"
# When run via the Docker wrapper (./run.sh), OUT is preset to /out and the
# host out/ dir is volume-mounted there. Outside the container, fall back to
# the repo's own out/.
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/out}"
MANIFESTS="$(cd "$(dirname "$0")/../manifests" && pwd)"

# Workload tunables
RPS=2000
EVENT_INTERVAL_S=75
WARMUP_S=5
TAIL_S=110

# EVENTS=rollout,consolidation,...  (comma-separated) lets the caller pin a
# deterministic event sequence -- useful for matrix runs that compare
# all-rollout vs all-consolidation vs mixed across modes. When unset,
# NUM_EVENTS defaults to 4 and the dispatcher picks each event randomly.
if [ -n "${EVENTS:-}" ]; then
  IFS=',' read -ra DECLARED_EVENTS <<< "$EVENTS"
  NUM_EVENTS=${#DECLARED_EVENTS[@]}
else
  NUM_EVENTS=4
fi
DURATION_MS=$(( (WARMUP_S + NUM_EVENTS * EVENT_INTERVAL_S + TAIL_S) * 1000 ))

mkdir -p "$OUT"
export NS

# ============================================================================
# Run identifier
# ============================================================================

# Per-run subdirectory: timestamped + tagged with key config so multiple runs
# accumulate side-by-side without overwriting.
compute_run_tag() {
  # matrix.sh sets MATRIX_LABEL to the scenario's unique label and we use it
  # directly as the tag -- this lets matrix runs do multiple iterations of
  # the same env-var combination without RUN_DIR collisions at parallel start.
  if [ -n "${MATRIX_LABEL:-}" ]; then
    echo "$MATRIX_LABEL"
    return
  fi
  local tag
  if [ "${WITHOUT_ISTIO:-0}" = "1" ]; then tag="noistio"
  elif [ "${WAYPOINT_ENABLED:-0}" = "1" ]; then tag="waypoint"
  else tag="nowaypoint"
  fi
  [ "${CLIENT_FIX:-0}" = "1" ] && tag="${tag}-clientfix"
  if [ -n "${EVENTS:-}" ]; then
    local unique_count seq_label
    unique_count=$(echo "$EVENTS" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')
    if [ "$unique_count" = "1" ]; then
      seq_label=$(echo "$EVENTS" | cut -d',' -f1)
    else
      seq_label="mixed"
    fi
    tag="${tag}-${seq_label}"
  fi
  echo "$tag"
}

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_TAG=$(compute_run_tag)
RUN_DIR="$OUT/runs/${RUN_TS}-${RUN_TAG}"
EVENTS_LOG="$RUN_DIR/events.log"
REPORT="$RUN_DIR/report.txt"

# ============================================================================
# Cluster lifecycle
# ============================================================================

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

create_cluster() {
  echo "==> creating kind cluster '$CLUSTER' (topology from manifests/kind-cluster.yaml)"
  kind create cluster --name "$CLUSTER" --config="$MANIFESTS/kind-cluster.yaml"
}

reuse_cluster() {
  echo "==> reusing existing kind cluster '$CLUSTER'"
  # Orchestrator container is fresh each invocation; populate its kubeconfig
  # from the existing cluster so kubectl works without going through kind create.
  kind export kubeconfig --name "$CLUSTER" >/dev/null
}

discover_backend_workers() {
  BACKEND_WORKERS=($(kubectl get nodes -l role=backend -o jsonpath='{.items[*].metadata.name}'))
}

restore_stopped_workers() {
  # Previous runs may have docker-stopped + cordoned any backend worker to
  # simulate the EC2 instance terminate. Bring all of them back so the server
  # Deployment has full capacity for this run.
  local w
  for w in "${BACKEND_WORKERS[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$w" 2>/dev/null)" = "false" ]; then
      echo "    restoring stopped worker '$w'"
      docker start "$w" >/dev/null
      kubectl wait node/"$w" --for=condition=Ready --timeout=60s >/dev/null
    fi
    if kubectl get node "$w" -o jsonpath='{.spec.unschedulable}' 2>/dev/null | grep -q true; then
      kubectl uncordon "$w" >/dev/null
    fi
  done
}

# ============================================================================
# Mesh setup
# ============================================================================

load_istio_images_into_kind() {
  # matrix.sh exports istio images to tarballs at $OUT/.istio-tarballs/
  # before any scenario starts. Each scenario's reproduce.sh then loads
  # via `kind load image-archive` from the shared tarball, avoiding both:
  #   1. concurrent `docker save` races on the host daemon
  #   2. the multi-arch manifest digest issue with `kind load docker-image`
  #      on Docker Desktop (which can't resolve the foreign-platform
  #      manifest digest in the saved tarball)
  # Skips silently when the tarballs don't exist (single-scenario ./run.sh
  # bypasses matrix.sh; istioctl install then pulls per cluster as usual).
  local tarball_dir="$OUT/.istio-tarballs"
  [ -d "$tarball_dir" ] || return 0
  local img tarball
  for img in pilot proxyv2 install-cni ztunnel; do
    tarball="$tarball_dir/${img}.tar"
    if [ -f "$tarball" ]; then
      kind load image-archive "$tarball" --name "$CLUSTER" >/dev/null
    fi
  done
}

install_istio_ambient() {
  echo "==> installing istio ambient profile (with waypoint anti-affinity)"
  load_istio_images_into_kind
  istioctl install -f "$MANIFESTS/istio-operator.yaml" -y
  echo "==> waiting for ztunnel + istio-cni-node to be ready"
  kubectl rollout status -n istio-system ds/ztunnel --timeout=180s
  kubectl rollout status -n istio-system ds/istio-cni-node --timeout=120s
}

enroll_namespace_in_ambient() {
  echo "==> applying ambient-enrolled namespace manifest"
  envsubst < "$MANIFESTS/namespace.yaml" | kubectl apply -f -
  # istio-cni-node enrolls a labeled namespace within a few seconds of
  # seeing it in its informer cache. Sleep briefly so pods created next
  # get iptables redirects installed synchronously during pod creation.
  sleep 10
}

ensure_plain_namespace() {
  echo "==> WITHOUT_ISTIO=1: skipping istio install (plain Kubernetes baseline)"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  # On cluster reuse, the namespace may carry the ambient label from a
  # previous istio-enabled run. Strip it so this run is NOT mesh-enrolled.
  kubectl label ns "$NS" istio.io/dataplane-mode- 2>/dev/null || true
}

ensure_gateway_api_crds() {
  echo "==> ensuring Kubernetes Gateway API CRDs are installed (idempotent)"
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml >/dev/null
}

# ============================================================================
# Workload setup
# ============================================================================

load_images_into_kind() {
  echo "==> loading server and client images into kind"
  # Both images are built on the host (see run.sh). Always re-load so
  # fast-iterate picks up rebuilt images.
  kind load docker-image ztunnel-rst-repro-server:local --name "$CLUSTER"
  kind load docker-image ztunnel-rst-repro-client:local --name "$CLUSTER"
}

apply_workload_manifests() {
  echo "==> applying server + client manifests"
  envsubst < "$MANIFESTS/server.yaml" | kubectl apply -n "$NS" -f -
  # Pods are immutable for image, so on re-run delete+recreate the client
  # to pick up rebuilt images. Server is a Deployment; rollout-restart it.
  if kubectl get pod -n "$NS" client >/dev/null 2>&1; then
    kubectl delete pod -n "$NS" client --grace-period=1 --wait=true 2>/dev/null || true
  fi
  envsubst < "$MANIFESTS/client.yaml" | kubectl apply -n "$NS" -f -
  kubectl rollout restart -n "$NS" deployment/server
}

enable_waypoint() {
  echo "==> WAYPOINT_ENABLED=1: applying waypoint Gateway, HPA, PDB"
  envsubst < "$MANIFESTS/waypoint.yaml" | kubectl apply -n "$NS" -f -
  kubectl label svc -n "$NS" server istio.io/use-waypoint=server-waypoint --overwrite
  kubectl wait -n "$NS" --for=condition=Programmed gateway/server-waypoint --timeout=120s
  # Pin the auto-generated waypoint Deployment to the dedicated waypoint
  # nodepool (workers labeled role=waypoint). Gateway API doesn't expose
  # nodeSelector, so patch after the controller has created the Deployment.
  kubectl patch deployment -n "$NS" server-waypoint -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"role":"waypoint"}}}}}'
  kubectl rollout status -n "$NS" deployment/server-waypoint --timeout=120s
  # VirtualService (retries on gateway-error) + DestinationRule (outlier
  # detection). Waypoint picks them up via xDS; no caller-side change.
  envsubst < "$MANIFESTS/waypoint-traffic-policy.yaml" | kubectl apply -n "$NS" -f -
}

disable_waypoint() {
  # Make sure no waypoint label/Gateway lingers from a previous run.
  kubectl label svc -n "$NS" server istio.io/use-waypoint- 2>/dev/null || true
  kubectl delete -n "$NS" gateway/server-waypoint 2>/dev/null || true
}

wait_for_workloads_ready() {
  echo "==> waiting for server + client to be ready"
  kubectl rollout status -n "$NS" deployment/server --timeout=120s
  kubectl wait -n "$NS" --for=condition=ready pod/client --timeout=60s
}

# ============================================================================
# Measurement
# ============================================================================

start_pcap_capture() {
  echo "==> starting tcpdump inside client pod (pod-netns capture)"
  # -s 96 truncates each packet (just enough for ethernet + IP + TCP flags).
  # Filter: only TCP close events + HBONE port traffic, drops the bulk volume
  # so tshark in the report step doesn't take forever to scan a big pcap.
  kubectl exec -n "$NS" client -- \
    tcpdump -i any -nn -s 96 -w - \
      '(tcp[tcpflags] & (tcp-fin|tcp-rst) != 0) or tcp port 15008' \
    > "$RUN_DIR/ztunnel.pcap" &
  TCPDUMP_PID=$!
  sleep 2
}

start_client_load() {
  echo "==> running Node.js client at ${RPS} rps for ${DURATION_MS}ms (${NUM_EVENTS} events, ${EVENT_INTERVAL_S}s apart)"
  kubectl exec -n "$NS" client -- env \
    HOST="server.$NS.svc.cluster.local" PORT=80 \
    RPS="$RPS" DURATION_MS="$DURATION_MS" \
    CLIENT_FIX="${CLIENT_FIX:-0}" \
    node /app/client.js \
    > "$RUN_DIR/client.log" 2>&1 &
  NC_PID=$!
}

# Side-channel observability: tail kubectl events + pod placement to dedicated
# logs while the test runs. Useful for explaining why specific time-buckets
# in the client error timeline have errors (correlate with cluster events).
# Lightweight; does not affect measurement.
start_cluster_observers() {
  ( kubectl get events -A --watch -o "go-template={{.lastTimestamp}}\t{{.namespace}}\t{{.involvedObject.kind}}/{{.involvedObject.name}}\t{{.reason}}\t{{.message}}{{\"\n\"}}" 2>/dev/null \
      > "$RUN_DIR/k8s-events.log" 2>&1 ) &
  EVENTS_WATCH_PID=$!
  ( while true; do
      printf "===%s===\n" "$(date +%H:%M:%S)"
      kubectl get pod -n "$NS" -o wide --no-headers 2>/dev/null
      sleep 5
    done > "$RUN_DIR/pod-placement.log" 2>&1 ) &
  POD_WATCH_PID=$!
}

stop_cluster_observers() {
  kill "$EVENTS_WATCH_PID" 2>/dev/null || true
  kill "$POD_WATCH_PID" 2>/dev/null || true
  wait "$EVENTS_WATCH_PID" 2>/dev/null || true
  wait "$POD_WATCH_PID" 2>/dev/null || true
}

# Two production-realistic disruption events:
#
# consolidation: cordon a backend worker, drain non-DS pods gracefully,
#   docker stop -t 90 to send SIGTERM to the kind worker init. Kubelet GNS
#   in kind-cluster.yaml then runs staged shutdown -- non-critical pods
#   first, then critical pods like ztunnel with their own grace window.
#
# rollout: kubectl rollout restart deployment/server. Deployment controller
#   replaces all pods according to the strategy. Old pods get SIGTERM with
#   terminationGracePeriodSeconds; new pods schedule once old are gone.
#
# Neither uses `kubectl delete pod` -- both mirror what real Karpenter
# consolidations and CI deploys do, respectively.

note_event() {
  printf "%s\tevent=%s\ttype=%s\tt_ms=%s\n" \
    "$(date +%H:%M:%S)" "$1" "$2" "$(($(date +%s%N)/1000000))" \
    >> "$EVENTS_LOG"
}

# phase_log: append a wall-clock + offset-from-START_T marker to events.log
# so analysis can correlate cluster-state phases (cordon, drain, docker-stop,
# restore start, ready, uncordon, rollout-status-done) against client error
# timing on the same axis.
phase_log() {
  local phase="$1"
  local now=$(($(date +%s) - ${START_T:-$(date +%s)}))
  printf "%s\tphase=%s\tt=%ss\n" "$(date +%H:%M:%S)" "$phase" "$now" >> "$EVENTS_LOG"
}

do_consolidation() {
  local i="$1" w="$2"
  echo "==> [event $i/$NUM_EVENTS] disruption=consolidation (cordon + drain + SIGTERM-stop $w)"
  phase_log "cordon-start-${i}-${w}"
  kubectl cordon "$w" >/dev/null
  phase_log "drain-start-${i}-${w}"
  kubectl drain "$w" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s >/dev/null 2>&1 || true
  phase_log "drain-done-${i}-${w}"
  docker stop -t 90 "$w" >/dev/null 2>&1 || true
  phase_log "docker-stop-done-${i}-${w}"
}

do_rollout() {
  local i="$1"
  echo "==> [event $i/$NUM_EVENTS] disruption=rollout (kubectl rollout restart deployment/server)"
  kubectl rollout restart -n "$NS" deployment/server >/dev/null
  kubectl rollout status -n "$NS" deployment/server --timeout=120s >/dev/null 2>&1 || true
}

restore_worker() {
  local w="$1"
  if ! docker inspect "$w" >/dev/null 2>&1; then
    echo "    NOTE: worker container '$w' missing; recreating cluster is the only fix"
    return 1
  fi
  phase_log "restore-start-${w}"
  if [ "$(docker inspect -f '{{.State.Running}}' "$w" 2>/dev/null)" = "false" ]; then
    docker start "$w" >/dev/null
    phase_log "docker-started-${w}"
    kubectl wait node/"$w" --for=condition=Ready --timeout=120s >/dev/null
    phase_log "node-ready-${w}"
  fi
  kubectl uncordon "$w" >/dev/null 2>&1 || true
  phase_log "uncordoned-${w}"
  kubectl rollout status -n "$NS" deployment/server --timeout=120s >/dev/null
  phase_log "rollout-status-done-${w}"
}

# Pick event types up-front, deterministic from $EVENTS or random 50/50.
choose_event_types() {
  if [ -n "${EVENTS:-}" ]; then
    EVENT_TYPES=("${DECLARED_EVENTS[@]}")
  else
    EVENT_TYPES=()
    local i
    for i in $(seq 1 "$NUM_EVENTS"); do
      if [ $((RANDOM % 2)) -eq 0 ]; then EVENT_TYPES+=(consolidation); else EVENT_TYPES+=(rollout); fi
    done
  fi
}

# Fixed-schedule dispatcher: fires events at exact wall-clock offsets from
# its start, regardless of how long any individual handler takes. Each
# handler runs in a backgrounded subshell so a slow rollout cannot delay
# the next scheduled event.
dispatch_events() {
  local handler_pids=()
  local cons_count=0  # rotates drain target across BACKEND_WORKERS
  local i target now sleep_for chosen target_w
  for i in $(seq 1 "$NUM_EVENTS"); do
    target=$(( (i - 1) * EVENT_INTERVAL_S ))
    now=$(($(date +%s) - START_T))
    sleep_for=$((target - now))
    [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"

    chosen=${EVENT_TYPES[$((i-1))]}
    note_event "$i" "$chosen"
    case "$chosen" in
      consolidation)
        target_w="${BACKEND_WORKERS[$((cons_count % ${#BACKEND_WORKERS[@]}))]}"
        cons_count=$((cons_count + 1))
        # Drain + docker-stop only. Worker stays drained for the rest of
        # the run; we have 5 backend workers so 4 events still leave 1
        # alive to host surviving replicas. Restoring a kind worker is a
        # bench artifact -- the kubelet+CNI+ztunnel respawn after docker
        # restart triggers a `SandboxChanged` event ~30-40s later that
        # contaminates measurement of the *next* drain. In production a
        # consolidation followed by Karpenter scaling brings up a fresh
        # instance, not the same one coming back.
        ( do_consolidation "$i" "$target_w" ) &
        handler_pids+=($!)
        ;;
      rollout)
        ( do_rollout "$i" ) &
        handler_pids+=($!)
        ;;
    esac
  done
  # Wait for all handlers so the parent's `wait $DISPATCHER_PID` blocks
  # until cluster operations finish, not just until the loop ends.
  local pid
  for pid in "${handler_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

stop_capture_and_client() {
  echo "==> stopping tcpdump"
  kill "$TCPDUMP_PID" 2>/dev/null || true
  wait "$TCPDUMP_PID" 2>/dev/null || true
  kill "$NC_PID" 2>/dev/null || true
}

# ============================================================================
# Reporting
# ============================================================================

generate_report() {
  echo "==> generating run report"
  {
    echo "==================== RUN CONFIG ===================="
    echo "timestamp:         $RUN_TS"
    echo "tag:               $RUN_TAG"
    echo "rps:               $RPS"
    echo "num_events:        $NUM_EVENTS"
    echo "event_interval_s:  $EVENT_INTERVAL_S"
    echo "client_window_ms:  $DURATION_MS"
    echo "without_istio:     ${WITHOUT_ISTIO:-0}"
    echo "waypoint_enabled:  ${WAYPOINT_ENABLED:-0}"
    echo "client_fix:        ${CLIENT_FIX:-0}"
    echo "cluster:           $CLUSTER"
    echo "  backend workers:   ${BACKEND_WORKERS[*]} (drain rotates)"
    echo "  client worker:     $(kubectl get nodes -l role=client -o jsonpath='{.items[*].metadata.name}')"
    echo "  waypoint workers:  $(kubectl get nodes -l role=waypoint -o jsonpath='{.items[*].metadata.name}')"
    echo
    echo "==================== CLIENT FINAL STATS ===================="
    grep -E '^firing|^final|^\[(undici|axios)\]' "$RUN_DIR/client.log" || true
    echo
    echo "==================== ERROR COUNTS PER CLIENT ===================="
    local who total
    for who in fetch axios; do
      total=$(grep -cE "^\[$who " "$RUN_DIR/client.log" 2>/dev/null || echo 0)
      echo "$who errors: $total"
      grep -E "^\[$who " "$RUN_DIR/client.log" 2>/dev/null \
        | grep -oE 'code=[A-Z_0-9]+' | sort | uniq -c | sed 's/^/  /' || true
    done
    echo
    echo "==================== ERROR TIMING (per 1s bucket) ===================="
    for who in fetch axios; do
      echo "[$who]"
      grep -E "^\[$who " "$RUN_DIR/client.log" 2>/dev/null \
        | awk -F't=' '{print $2}' | awk -F'ms' '{printf("%d\n", $1/1000)}' \
        | sort -n | uniq -c | awk '{printf("  t=%2ss: %s errors\n", $2, $1)}' || true
    done
    echo
    echo "==================== WIRE-LEVEL CLOSE FLAGS (pcap) ===================="
    echo "pcap size: $(du -h "$RUN_DIR/ztunnel.pcap" 2>/dev/null | awk '{print $1}')"
    if command -v tshark >/dev/null 2>&1; then
      # Run both tshark passes in parallel with a short timeout so a large
      # waypoint pcap (200MB+) can't blow the report budget. If tshark gets
      # killed, print "?" placeholders -- pcap is on disk for offline analysis.
      local fin_f rst_f fin_pid rst_pid fin rst
      fin_f="$RUN_DIR/.fin.tmp"
      rst_f="$RUN_DIR/.rst.tmp"
      ( timeout 25 tshark -r "$RUN_DIR/ztunnel.pcap" -Y 'tcp.flags.fin == 1' 2>/dev/null | wc -l | tr -d ' ' > "$fin_f" ) &
      fin_pid=$!
      ( timeout 25 tshark -r "$RUN_DIR/ztunnel.pcap" -Y 'tcp.flags.reset == 1' 2>/dev/null | wc -l | tr -d ' ' > "$rst_f" ) &
      rst_pid=$!
      wait $fin_pid 2>/dev/null || true
      wait $rst_pid 2>/dev/null || true
      fin=$(cat "$fin_f" 2>/dev/null)
      rst=$(cat "$rst_f" 2>/dev/null)
      rm -f "$fin_f" "$rst_f"
      echo "FIN packets: ${fin:-?}"
      echo "RST packets: ${rst:-?}"
    else
      echo "(tshark not present in this image; run separately on the pcap)"
    fi
    echo
    echo "==================== DISRUPTION EVENTS ===================="
    if [ -s "$EVENTS_LOG" ]; then
      while IFS= read -r line; do echo "  $line"; done < "$EVENTS_LOG"
      echo
      echo "type breakdown:"
      awk -F'type=' '{print $2}' "$EVENTS_LOG" | awk '{print $1}' \
        | sort | uniq -c | sed 's/^/  /'
    else
      echo "(no events recorded)"
    fi
    echo
    echo "==================== POD PLACEMENT (final state) ===================="
    kubectl get pod -n "$NS" -o wide --no-headers 2>/dev/null | awk '{printf("  %-50s %-10s %s\n", $1, $3, $7)}'
  } > "$REPORT" 2>&1
}

update_index_tsv() {
  local index="$OUT/runs/INDEX.tsv"
  if [ ! -f "$index" ]; then
    printf "timestamp\ttag\twaypoint\tfetch_errs\tfetch_resets\taxios_errs\taxios_resets\twire_fin\twire_rst\trun_dir\n" > "$index"
  fi
  local fetch_errs fetch_resets axios_errs axios_resets wire_fin wire_rst
  fetch_errs=$(grep -cE '^\[fetch ' "$RUN_DIR/client.log" 2>/dev/null || echo 0)
  fetch_resets=$(grep -E '^\[fetch ' "$RUN_DIR/client.log" 2>/dev/null | grep -cE 'code=(UND_ERR_SOCKET|ECONNRESET)' || echo 0)
  axios_errs=$(grep -cE '^\[axios ' "$RUN_DIR/client.log" 2>/dev/null || echo 0)
  axios_resets=$(grep -E '^\[axios ' "$RUN_DIR/client.log" 2>/dev/null | grep -cE 'code=ECONNRESET' || echo 0)
  wire_fin=$(grep -E '^FIN packets:' "$REPORT" | awk '{print $3}')
  wire_rst=$(grep -E '^RST packets:' "$REPORT" | awk '{print $3}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$RUN_TS" "$RUN_TAG" "${WAYPOINT_ENABLED:-0}" \
    "$fetch_errs" "$fetch_resets" "$axios_errs" "$axios_resets" \
    "${wire_fin:-?}" "${wire_rst:-?}" \
    "$(basename "$RUN_DIR")" >> "$index"
}

# ============================================================================
# Main
# ============================================================================

if [ "${WAYPOINT_ENABLED:-0}" = "1" ] && [ "${WITHOUT_ISTIO:-0}" = "1" ]; then
  echo "ERROR: WAYPOINT_ENABLED=1 cannot be combined with WITHOUT_ISTIO=1 (waypoints require istio)" >&2
  exit 1
fi

mkdir -p "$RUN_DIR"
: > "$EVENTS_LOG"
echo "==> run output dir: $RUN_DIR"

# Cluster: reuse if present, otherwise create + provision the mesh layer.
if cluster_exists; then
  reuse_cluster
  discover_backend_workers
  restore_stopped_workers
else
  create_cluster
  discover_backend_workers
  if [ "${WITHOUT_ISTIO:-0}" = "1" ]; then
    ensure_plain_namespace
  else
    install_istio_ambient
    enroll_namespace_in_ambient
  fi
fi

# On reuse, the namespace may carry the ambient label from a previous
# istio-enabled run. Strip it so this run is plain Kubernetes.
[ "${WITHOUT_ISTIO:-0}" = "1" ] && \
  kubectl label ns "$NS" istio.io/dataplane-mode- 2>/dev/null || true

# Gateway API CRDs are required for the waypoint Gateway resource. Apply
# them whenever istio is in play (idempotent if already installed).
[ "${WITHOUT_ISTIO:-0}" != "1" ] && ensure_gateway_api_crds

# Workloads.
load_images_into_kind
apply_workload_manifests
if [ "${WAYPOINT_ENABLED:-0}" = "1" ]; then
  enable_waypoint
else
  disable_waypoint
fi
wait_for_workloads_ready

# Measurement.
start_pcap_capture
start_cluster_observers
start_client_load
sleep 5  # let the client warm pools before triggering events
choose_event_types
START_T=$(date +%s)
dispatch_events &
DISPATCHER_PID=$!

echo "==> waiting for client run to complete"
wait "$NC_PID" 2>/dev/null || true
# Let the dispatcher and any backgrounded handlers finish so the cluster
# isn't mid-rollout when we tear down. (Don't `wait` with no args here:
# tcpdump is also a child of this shell and never exits on its own.)
echo "==> waiting for in-flight event handlers to finish"
wait "$DISPATCHER_PID" 2>/dev/null || true

stop_capture_and_client
stop_cluster_observers

# Reporting.
generate_report
update_index_tsv

echo
echo "Done."
echo "  run dir:   $RUN_DIR"
echo "  report:    $REPORT"
echo "  index:     $OUT/runs/INDEX.tsv"
echo
cat "$REPORT"
