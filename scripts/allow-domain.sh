#!/bin/bash
# Manually add one domain to the running egress allowlist (root, host).
# The normal path is the Telegram-approved append + watcher; this is the
# fallback for when you're already at a shell.
# Usage: allow-domain.sh api.example.com
set -euo pipefail

d="${1:?usage: allow-domain.sh <domain>}"
if ! [[ "$d" =~ ^\.?([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
  echo "refusing: '$d' is not domain-shaped" >&2
  exit 1
fi

# Append to BOTH copies: the watcher's append-only check requires the deployed
# file to stay a byte prefix of the working copy, so a deploy-only append would
# make it reject every subsequent legitimate append until reconciled.
# Deploy copy first — if the watcher fires between the two appends it logs a
# harmless REJECT; the other order can double-apply the line.
echo "$d" >> /root/pa-infra/proxy/allowed-domains.txt
echo "$d" >> /home/padraig/git/pa-infra/proxy/allowed-domains.txt
docker exec calproxy squid -k reconfigure
echo "allowed: $d (remember: commit the working-copy append)"
