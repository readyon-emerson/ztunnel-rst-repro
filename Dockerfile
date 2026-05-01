# Self-contained orchestrator image for the ambient + node-consolidation
# investigation. Bakes kind, istioctl, kubectl, tshark, and the repro
# scripts into one image so the host only needs Docker. The Node.js client
# and server images are built separately by run.sh and loaded into the
# kind cluster via `kind load docker-image`.
#
# See ../README.md for what this repo demonstrates.
#
# Notes:
# - The container needs the host's Docker socket because kind spawns its
#   "cluster nodes" as sibling containers, not nested ones.
# - The kind cluster runs on the host; this container is just the orchestrator.
FROM debian:bookworm-slim

ARG KIND_VERSION=0.24.0
ARG ISTIO_VERSION=1.29.2
ARG KUBECTL_VERSION=1.33.0
ARG DOCKER_CLI_VERSION=27.3.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gettext-base tshark \
    && rm -rf /var/lib/apt/lists/*

# Use Docker's official static CLI binary; the Debian-shipped docker.io is too
# old (API 1.41) to talk to a recent Docker Desktop daemon (needs >= 1.44).
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/ \
    && rm -rf /tmp/docker

RUN curl -fsSL "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64" \
      -o /usr/local/bin/kind \
    && chmod +x /usr/local/bin/kind

RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

RUN curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /tmp \
    && mv "/tmp/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/ \
    && rm -rf "/tmp/istio-${ISTIO_VERSION}"

WORKDIR /repro
COPY scripts/   /repro/scripts/
COPY manifests/ /repro/manifests/
RUN chmod +x /repro/scripts/*.sh

# Map the script's output dir to /out so it lands on the host volume.
ENV OUT=/out

ENTRYPOINT ["/repro/scripts/reproduce.sh"]
