#!/bin/bash
# Deploy pa-infra — run as root on the host, from the deploy clone.
# This is the review moment: run `git -C /root/pa-infra log -p ..origin/main`
# and read the diff BEFORE running this script.
set -euo pipefail

cd /root/pa-infra
# The watcher legitimately dirties the deployed allowlist between deploys:
# domains Pádraig approved on the hub page are live here before anyone
# commits them. Keep them across the pull (a deploy must not quietly undo an
# approval, and since 2026-11-11 re-applying them would need approving again).
live=$(mktemp)
cp proxy/allowed-domains.txt "$live"
git checkout -- proxy/allowed-domains.txt
git pull --ff-only
if head -c "$(stat -c %s proxy/allowed-domains.txt)" "$live" | cmp -s - proxy/allowed-domains.txt; then
  cp "$live" proxy/allowed-domains.txt
fi
rm -f "$live"

# --pull refreshes the ubuntu base; `pull` refreshes squid and socat. Without
# these, images only ever update by accident (squid sat 11 months stale).
docker compose build --pull
docker compose pull --ignore-buildable
docker compose up -d

# Install/refresh the allowlist watcher from the ROOT-OWNED clone, so Cal's
# working copy can never change the validation logic that gates it.
cp host/allowlist-watcher.path host/allowlist-watcher.service /etc/systemd/system/
chmod 755 host/allowlist-apply.sh
systemctl daemon-reload
systemctl enable --now allowlist-watcher.path

# The status page and approval desk (tailnet only; see host/hub/hub.py). It
# needs /etc/cal-hub.conf (OWNER, HUB_URL) and a `tailscale serve` port, both
# set up once by hand: see ARCHITECTURE.md, "cal-hub".
cp host/hub/cal-hub.service /etc/systemd/system/
mkdir -p /var/lib/cal-hub
systemctl daemon-reload
systemctl enable cal-hub.service
systemctl restart cal-hub.service

host/allowlist-apply.sh

echo "deployed: $(git rev-parse --short HEAD)"
