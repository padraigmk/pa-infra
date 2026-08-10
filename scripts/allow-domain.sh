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

echo "$d" >> /root/pa-infra/proxy/allowed-domains.txt
docker exec calproxy squid -k reconfigure
echo "allowed: $d"
