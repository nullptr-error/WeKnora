#!/usr/bin/env bash
#
# Cloud Agent install phase for WeKnora.
#
# Provisions everything that is durable and can be baked into the environment
# build/snapshot: the Docker engine, fuse-overlayfs (required for nested
# containers in the Cloud Agent VM), the deployment .env file, and a pre-pull
# of the core Compose images so fresh agents boot quickly.
#
# Per-boot work (starting dockerd, bringing up the stack) lives in start.sh.
# This script is idempotent and safe to run repeatedly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[0;34m[install]\033[0m %s\n' "$1"; }

# 1. Docker engine + compose plugin (idempotent).
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker engine via get.docker.com ..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
else
  log "Docker already installed: $(docker --version)"
fi

# 2. fuse-overlayfs: the Cloud Agent VM is itself a container, so the default
#    overlay2 storage driver is unavailable. fuse-overlayfs is the fallback.
log "Ensuring fuse-overlayfs is installed ..."
sudo apt-get update -qq
sudo apt-get install -y -qq fuse-overlayfs

# 3. Deployment configuration. Only seed from the template when absent so any
#    edits the user makes to .env are preserved across installs.
if [ ! -f .env ]; then
  log "Creating .env from .env.example"
  cp .env.example .env
else
  log ".env already present, leaving it untouched"
fi

# 4. Best-effort pre-pull of the core Compose images so they are baked into the
#    environment build and fresh agents start without a slow first-boot pull.
#    This is an optimization only: any failure here must NOT fail the install,
#    because start.sh pulls on demand as a fallback.
prepull_images() {
  log "Pre-pulling core Compose images (best-effort) ..."
  local started_here=0
  if ! sudo docker info >/dev/null 2>&1; then
    sudo bash -c 'nohup dockerd --storage-driver=fuse-overlayfs >/var/log/weknora-dockerd-install.log 2>&1 &'
    started_here=1
    for _ in $(seq 1 30); do
      sudo docker info >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  if sudo docker info >/dev/null 2>&1; then
    sudo docker compose pull postgres redis docreader app frontend || true
  else
    log "dockerd not reachable during install; skipping pre-pull (start.sh will pull)"
  fi
  # Stop the temporary daemon we started; image layers persist on disk.
  if [ "$started_here" = "1" ]; then
    sudo pkill -x dockerd 2>/dev/null || true
  fi
}
prepull_images || true

log "Install complete."
