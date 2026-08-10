#!/bin/bash
# Deploy pa-infra — run as root on the host, from the deploy clone.
# This is the review moment: run `git -C /root/pa-infra log -p ..origin/main`
# and read the diff BEFORE running this script.
set -euo pipefail

cd /root/pa-infra
git pull --ff-only

docker compose build
docker compose up -d

# Install/refresh the allowlist watcher from the ROOT-OWNED clone, so Cal's
# working copy can never change the validation logic that gates it.
cp host/allowlist-watcher.path host/allowlist-watcher.service /etc/systemd/system/
chmod 755 host/allowlist-apply.sh
systemctl daemon-reload
systemctl enable --now allowlist-watcher.path

echo "deployed: $(git rev-parse --short HEAD)"
