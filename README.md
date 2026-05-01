# HTTP error rates with Istio ambient + waypoint, under pod disruption

A bench for measuring socket-level errors HTTP keep-alive clients see when Kubernetes backends are gracefully restarted, drained, or evicted. Compares plain Kubernetes, Istio ambient (ztunnel only), and Istio ambient + waypoint. Runs locally in a kind cluster. Only Docker is required on the host.

A naive setup gives "thousands of errors per consolidation cycle, 10× variance run-to-run". Not actionable. With the configuration described below, mesh-handled disruption costs ~6 errors per 4-event cycle (0.00075% of ~800K requests). 1,000× lower.

## Setup

A 2,000 rps Node.js client (half via undici `fetch`, half via `axios`, both stock defaults) drives ~800,000 requests over ~7 minutes against a 4-replica Node.js HTTP service that hangs each request 1 to 3 seconds before responding (so requests are actually in flight when disruption hits). Four disruption events fire 75s apart while the client runs.

**Hardening on by default.** Without these, missing-config errors swamp everything else and no two modes are distinguishable:

- pod anti-affinity (preferred, hostname topology) on backend replicas
- kubelet `GracefulNodeShutdown` (`shutdownGracePeriod: 60s`, `shutdownGracePeriodCriticalPods: 30s`) so SIGTERM on the node honors pod `terminationGracePeriodSeconds` instead of becoming SIGKILL
- `http-terminator` in the application: idle keep-alives get a clean FIN on SIGTERM, in-flight responses get `Connection: close`, force-destroy after 15s
- `PodDisruptionBudget` `minAvailable: 2` on a 4-replica deployment
- `RollingUpdate maxSurge: 1, maxUnavailable: 0`
- lame-duck `readinessProbe` plus `preStop: touch /tmp/draining && sleep 15`. The probe checks for absence of the file, so the pod flips NotReady within ~1s of preStop start; EndpointSlice removes it before SIGTERM hits

**Two disruption classes.** Neither uses `kubectl delete pod`, neither models a real-world graceful event:

- **rollout**: `kubectl rollout restart deployment/server`. Models a CI deploy
- **consolidation**: cordon a backend node, drain (respecting PDB), `docker stop -t 90` to send SIGTERM and trigger kubelet GNS. Models AWS instance terminate after Karpenter completes its drain

**12-node topology** (`manifests/kind-cluster.yaml`):

```
1 control-plane
8 backend workers   (4 events drain 4 of 8; the other 4 stay alive throughout)
1 client worker     (runs the load generator, never drained)
2 waypoint workers  (host the waypoint Deployment, never drained)
```

## Findings

Numbers are total errors per run, 4 runs each. Each row adds one piece of configuration on top of the previous.

| configuration | rollout (4 runs) | consolidation (4 runs) |
|---|---|---|
| anti-affinity on waypoint only (the upstream-recommended HA shape) | `[2, 3, 3, 3]` stdev 0 | `[5375, 5658, 11067, 1535]` **stdev 3919** |
| + pin waypoint to a dedicated nodepool | `[7, 7, 4, 4]` stdev 2 | `[2958, 1951, 2171, 2851]` stdev 497 |
| + `outlierDetection` on the upstream | `[3, 1, 7, 9]` stdev 4 | `[423, 687, 503, 508]` stdev 112 |
| + 8 backend workers, no kind restore (final) | `[1, 0, 4, 2]` stdev 2 | **`[1, 1, 0, 21]` mean 6, stdev 10** |

Error patterns across all rows are clean L7 (`HTTP_503` / `ERR_BAD_RESPONSE`). No L4 RSTs, no `UND_ERR_SOCKET`. The result is safe for non-idempotent workloads -- a clean `503` is retryable; a connection cut mid-write isn't.

### Waypoints need their own nodepool

`preferredDuringScheduling` anti-affinity is non-binding. With 2 waypoint replicas and several available nodes, the scheduler still places waypoints on the same nodes that backend workloads run on. When a consolidation event drains one of those nodes, the waypoint pod cycles too. The result is L4 disruption (TCP resets from the waypoint's downstream connections being torn down) layered on top of the L7 disruption a mesh is supposed to absorb. Some runs land on the coincidence; some don't. That coincidence accounts for the 10× variance in the first row.

`PodDisruptionBudget minAvailable: 1` doesn't help. It only blocks evictions when *both* replicas are on the drained node, which is rare. The common case (one replica on the drained node, one elsewhere) proceeds normally and the cycle cost lands on the measurement.

The fix is topological: a dedicated nodepool labeled `role: waypoint`, and a `nodeSelector` patch on the auto-generated waypoint Deployment after istio's gateway-controller creates it (Gateway API does not expose `nodeSelector` directly). Mirrors the production pattern of running Envoy-class proxies on a stable platform/system nodepool, separate from workload nodes that Karpenter consolidates.

### Outlier detection on the upstream `DestinationRule`

After pinning, residual errors are a small handful of in-flight requests Envoy queues onto each pod just before it stops responding. Outlier detection shortens that window: Envoy ejects a failing upstream from the LB pool faster than EDS would, so new requests bypass a draining pod sooner.

Production-faithful values (`manifests/waypoint-traffic-policy.yaml`):

```yaml
outlierDetection:
  consecutive5xxErrors: 5     # tolerate transient blips, eject on sustained failure
  interval: 30s               # observation window; counter resets if quiet
  baseEjectionTime: 30s       # initial ejection; Envoy doubles on re-ejection
  maxEjectionPercent: 50      # bench-only; prod with >=10 replicas should be 10
  minHealthPercent: 50        # never eject if it would drop us below half-healthy
```

`maxEjectionPercent` is the one bench-vs-prod parameter. At 4 replicas, Envoy floors `replicas * percent` to an integer, so `10` rounds to 0 and the policy is silently inert. The bench uses `50` so ejection actually fires (2 of 4 max). Production at typical fleet size should set it to `10`, aligned with PDB headroom.

### Drained nodes don't come back

The bench leaves drained workers down for the rest of the run rather than restoring them. Cycling the same kind worker via `docker stop` + `docker start` reinstalls the Istio CNI plugin chain, and ~30-40 seconds later kubelet detects the chain change, recreates the ztunnel pod's sandbox, and ztunnel returns `500` on its readiness probe for several seconds. A consolidation event landing in that window measures CNI-respawn turbulence rather than mesh-plus-drain interaction.

That artifact does not exist in production. Karpenter consolidation followed by EC2 scale-up brings up a fresh instance with fresh kubelet from boot, not the same one rebooting. Modelling the production behavior in kind means provisioning enough backend capacity that 4 events leave half the fleet alive, and not bringing drained workers back during the run.

### Fleet headroom is a real production knob

A 5-backend version of the bench (4 events drain 4 of 5) produces bimodal results: `[1100, 3, 1142, 0]`. Either ~0 errors or ~1,100, depending on placement luck.

Mechanism: by event 4, three workers are already drained. Pods are concentrated on workers 4 and 5. When event 4 drains worker 4, surviving pods land on worker 5. Anti-affinity is preferred, not required, so the deployment doesn't refuse to schedule. If pre-event placement was 3-on-4 / 1-on-5, drain hits the 60s timeout before all evictions finish, the deployment briefly drops to ~25% capacity, and waypoint surfaces a flood of `503`s. If placement was 2/2, drain completes gracefully and the cycle costs ~0 errors.

This is the actual production failure mode you'd see if Karpenter consolidates several backend nodes in close succession against a tightly-sized fleet. With 8 backends, the surviving 4 host the deployment throughout and the cost collapses to single digits. Production translation: keep enough headroom that a consolidation cascade can't compress pods onto a single node, and rate-limit Karpenter's consolidation aggressiveness.

## A note on retries

A `VirtualService` with `retries: { retryOn: gateway-error,connect-failure,refused-stream,reset }` on top of the rest of this stack doesn't help. Ambient waypoint doesn't fully honor `VirtualService` retries (the canonical retry path is Gateway API `HTTPRoute` on the experimental channel), and the few that do fire shift error patterns from clean L7 503s to L4 RST floods.

That's fine, because **retries on a connection cut mid-request are unsafe for non-idempotent operations**. If a write gets the response cut mid-stream, the client cannot tell whether the server processed it before the connection died; retrying duplicates the write. Outlier detection ejects the failing pod *before* such a request lands on it, removing the duplication risk at the source instead of papering over with a retry that may double-write. For fully-idempotent workloads, retries via experimental Gateway API HTTPRoute layer cleanly on top.

## Production recommendations

- run waypoints on a separate nodepool from the workload nodes that consolidation targets
- set `outlierDetection` with `maxEjectionPercent` aligned to your PDB headroom (typically `10`)
- size the workload nodepool so a few simultaneous consolidations can't compress pods onto a single node, and rate-limit Karpenter's consolidation aggressiveness
- skip `VirtualService` retries unless every operation is idempotent

## Reproducing

```bash
git clone <this-repo>
cd ztunnel-rst-repro

# Single scenario, leaves the cluster up afterward for inspection:
./run.sh                           # ambient + waypoint, default events
WITHOUT_ISTIO=1 ./run.sh           # plain Kubernetes (no mesh)

# Full variance matrix (8 runs, 3 parallel, ~40 min):
CONFIG=matrix-stress.yaml MAX_PARALLEL=3 ./matrix.sh

# Force a clean rebuild after changing manifests:
./scripts/cleanup.sh --all
```

Each run lands in `out/runs/<timestamp>-<tag>/` with `client.log`, `events.log` (disruption events + per-phase markers like `drain-done`, `docker-stop-done`), `ztunnel.pcap`, `k8s-events.log`, `pod-placement.log`, and a generated `report.txt`. Top-level `out/runs/INDEX.tsv` accumulates one row per run.

To change topology, edit only `manifests/kind-cluster.yaml`. Workload manifests use `nodeSelector` against the role labels there.

## Out of scope

- latency. Every measurement is "did the request succeed"
- mTLS, identity, AuthorizationPolicy. Test server speaks plain HTTP
- gRPC bidirectional streaming. Workload is HTTP/1.1 request/response
- spot reclaims and hardware failures. Disruption events here are graceful
- multi-region or cross-cluster traffic. Single cluster
