#!/bin/bash
# Root-owned watcher action (R2.3): apply Cal's proposed egress-allowlist
# changes iff they are APPEND-ONLY and every added line is domain-shaped.
# Anything else is logged and ignored — left for a manual, reviewed deploy.
#
# Triggered by allowlist-watcher.path when Cal edits its working copy.
# Executes only from /root/pa-infra (deploy clone); Cal has no write path here.
set -uo pipefail

WORK=/home/padraig/git/pa-infra/proxy/allowed-domains.txt
DEPLOYED=/root/pa-infra/proxy/allowed-domains.txt
LOG=/var/log/cal-allowlist.log

log() { echo "$(date -Is) $*" >> "$LOG"; }

[ -f "$WORK" ] || exit 0
[ -f "$DEPLOYED" ] || { log "REJECT: deployed copy missing"; exit 0; }

deployed_size=$(stat -c %s "$DEPLOYED")
work_size=$(stat -c %s "$WORK")

if [ "$work_size" -eq "$deployed_size" ] && cmp -s "$DEPLOYED" "$WORK"; then
  exit 0  # no change
fi

# Append-only check: the deployed file must be an exact byte prefix of the
# working copy. Any edit or deletion of existing lines fails this.
if [ "$work_size" -lt "$deployed_size" ] || \
   ! cmp -s "$DEPLOYED" <(head -c "$deployed_size" "$WORK"); then
  log "REJECT: change is not append-only"
  exit 0
fi

added=$(tail -c +"$((deployed_size + 1))" "$WORK")

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  if ! [[ "$line" =~ ^\.?([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
    log "REJECT: line not domain-shaped: $line"
    exit 0
  fi
done <<< "$added"

cp "$WORK" "$DEPLOYED"
if docker exec calproxy squid -k reconfigure >/dev/null 2>&1; then
  log "APPLIED: $(echo "$added" | grep -cv '^\s*$\|^#') line(s): $(echo "$added" | tr '\n' ' ')"
else
  log "APPLIED file but squid reconfigure FAILED — check calproxy"
fi
