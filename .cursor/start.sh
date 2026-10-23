#!/usr/bin/env bash
#
# Cloud Agent start phase for WeKnora.
#
# Runs on every boot: starts the Docker daemon (nested-container aware), applies
# the bridge-netfilter workaround required for container-to-container traffic in
# the Cloud Agent VM, then brings up the core Compose stack and waits for the
# backend to become healthy.
#
# Idempotent: detects an already-running daemon / stack and reconciles instead
# of duplicating.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[0;34m[start]\033[0m %s\n' "$1"; }

# 1. Start dockerd if it is not already running.
if ! sudo docker info >/dev/null 2>&1; then
  log "Starting dockerd (fuse-overlayfs) ..."
  sudo bash -c 'nohup dockerd --storage-driver=fuse-overlayfs >/var/log/weknora-dockerd.log 2>&1 &'
  for _ in $(seq 1 30); do
    sudo docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi

if ! sudo docker info >/dev/null 2>&1; then
  log "ERROR: dockerd failed to start; see /var/log/weknora-dockerd.log"
  exit 1
fi
log "Docker daemon is up: $(sudo docker --version)"

# 2. Nested-container networking fix.
#    The VM runs Docker inside a container, so bridge frames on user-defined
#    networks are pushed through Docker's nftables FORWARD chains and dropped.
#    Disabling bridge-netfilter lets same-subnet container traffic switch at L2
#    (required for app -> postgres/redis/docreader). Must run each boot; the
#    sysctl only exists once dockerd has created the first bridge, hence it runs
#    after dockerd start. Non-fatal if the key is unavailable.
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0  >/dev/null 2>&1 || true
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true

# 3. Ensure deployment configuration exists (Compose requires .env to parse).
[ -f .env ] || cp .env.example .env

# 4. Bring up the core stack and wait for the backend health check.
log "Starting core services (postgres, redis, docreader, app, frontend) ..."
sudo docker compose up -d --wait --wait-timeout 300 || sudo docker compose up -d

# 5. Readiness confirmation: poll the backend /health endpoint.
for _ in $(seq 1 60); do
  if curl -fsS -m 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    log "WeKnora backend is healthy at http://localhost:8080 (UI at http://localhost)"
    break
  fi
  sleep 2
done

sudo docker compose ps || true
log "Start complete."
