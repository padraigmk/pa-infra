#!/bin/bash
# Root-owned watcher action (R2.3): apply Cal's proposed egress-allowlist
# changes iff they are APPEND-ONLY, domain-shaped, free of squid's bare/dotted
# redundancy conflicts, AND parse cleanly under the real squid binary.
# Anything else is rejected, left un-deployed, and reported to Pádraig.
#
# Triggered by allowlist-watcher.path when Cal edits its working copy.
# Executes only from /root/pa-infra (deploy clone); Cal has no write path here.
#
# Hardened 2026-08-20, after an append containing both `huggingface.co` and
# `.huggingface.co` was applied unvalidated. In squid a leading dot already
# matches the bare domain and all subdomains, so squid 6.13 treats that pair as
# redundant and refuses to start: "FATAL: Bungled squid.conf". calproxy
# terminated on every restart and crash-looped for ~8 minutes, cutting ALL
# egress including api.anthropic.com — the blast radius of this file is every
# outbound request, not just the domain being added.
#
# Three defects made that possible, all addressed below:
#   1. the shape regex accepted a leading dot, so the bad line looked valid;
#   2. the deployed copy was overwritten BEFORE squid ever saw the config, so
#      the breakage persisted across restarts;
#   3. a failed reconfigure only wrote a log line — no rollback, no alert.
#
# Failure policy is fail-CLOSED: if the change cannot be validated for any
# reason (docker down, image missing, scratch dir unwritable), it is not
# deployed. A stuck append costs Cal one domain; a bad deploy costs everything.
set -uo pipefail

WORK=/home/padraig/git/pa-infra/proxy/allowed-domains.txt
DEPLOYED=/root/pa-infra/proxy/allowed-domains.txt
SQUIDCONF=/root/pa-infra/proxy/squid.conf
BACKUP=/root/pa-infra/proxy/.allowed-domains.last-good
# Status file lives in Cal's bind-mounted working copy: Cal can read neither
# $LOG nor anything under /root, so this is its only channel for finding out
# that its own append was rejected.
STATUS=/home/padraig/git/pa-infra/proxy/.allowlist-status
LOG=/var/log/cal-allowlist.log
PROXY_IMAGE=ubuntu/squid:latest
TG_ENV=/home/padraig/cal-home/.claude/channels/telegram/.env
TG_CHAT=8502631426

log() { echo "$(date -Is) $*" >> "$LOG"; }

# Surface the outcome two ways: the status file above, and a Telegram message.
# A silent rejection is exactly what let the last failure run unnoticed.
notify() {
  local verdict="$1" detail="$2" token

  { echo "$(date -Is)"; echo "$verdict"; echo "$detail"; } > "$STATUS.tmp" 2>/dev/null \
    && mv "$STATUS.tmp" "$STATUS" 2>/dev/null
  chmod 644 "$STATUS" 2>/dev/null

  [ -r "$TG_ENV" ] || return 0
  # \042 = double quote, \047 = single quote. Never echoed or logged.
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" | cut -d= -f2- | tr -d '\042\047')
  [ -n "$token" ] || return 0
  curl -s -m 15 -o /dev/null \
    -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$TG_CHAT" \
    --data-urlencode "text=🛡️ Egress allowlist — ${verdict}

${detail}" || true
}

reject() {
  log "REJECT: $1"
  notify "CHANGE REJECTED, NOT DEPLOYED" "$1

Cal's working copy still has the proposed change; the live proxy is untouched and still running the last good allowlist. Fix the line and save again, or deploy by hand as root."
  exit 0
}

[ -f "$WORK" ] || exit 0
[ -f "$DEPLOYED" ] || { log "REJECT: deployed copy missing"; exit 0; }

deployed_size=$(stat -c %s "$DEPLOYED")
work_size=$(stat -c %s "$WORK")

if [ "$work_size" -eq "$deployed_size" ] && cmp -s "$DEPLOYED" "$WORK"; then
  exit 0  # no change
fi

# --- Gate 1: append-only ----------------------------------------------------
# The deployed file must be an exact byte prefix of the working copy. Any edit
# or deletion of an existing line fails this.
if [ "$work_size" -lt "$deployed_size" ] || \
   ! cmp -s "$DEPLOYED" <(head -c "$deployed_size" "$WORK"); then
  reject "The change is not append-only — existing lines were edited or removed.

This also happens after any hand-edit of the deployed copy: the two files diverge, and every later append from Cal fails this check until they are reconciled (cp the deployed copy over Cal's, or deploy Cal's by hand)."
fi

added=$(tail -c +"$((deployed_size + 1))" "$WORK")

# --- Gate 2: every added line is domain-shaped ------------------------------
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  if ! [[ "$line" =~ ^\.?([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
    reject "Added line is not domain-shaped: $line"
  fi
done <<< "$added"

# --- Gate 3: squid dstdomain redundancy -------------------------------------
# A dotted entry `.X` already matches X and every subdomain of X, so listing
# anything it covers alongside it is fatal to squid. This is a cheap, specific
# check that names the offending pair; gate 4 is the general backstop.
conflict=$(awk '
  /^[[:space:]]*(#|$)/ { next }
  { gsub(/[[:space:]]/, ""); if ($0 != "") entries[++n] = $0 }
  END {
    for (i = 1; i <= n; i++) {
      for (j = 1; j <= n; j++) {
        if (i == j) continue
        a = entries[i]; b = entries[j]
        if (a == b) { if (i < j) print "duplicate entry: " a; continue }
        if (substr(a, 1, 1) != ".") continue        # only dotted entries cover
        bare = substr(a, 2)                          # ".foo.com" -> "foo.com"
        stripped = b; sub(/^\./, "", stripped)
        # Exact suffix comparison, not a regex: dots in a domain are regex
        # wildcards, so ".foo.com" would otherwise "cover" fooXcom.
        suffix = "." bare
        if (stripped == bare || (length(stripped) > length(suffix) && \
            substr(stripped, length(stripped) - length(suffix) + 1) == suffix))
          print b " is already covered by " a
      }
    }
  }
' "$WORK")

if [ -n "$conflict" ]; then
  reject "Redundant entries — squid treats these as a FATAL config error and will refuse to start:

$conflict

In squid a leading dot matches the bare domain AND all subdomains, so the dotted form alone is what you want. Listing both forms is what took all egress down on 2026-08-20."
fi

# --- Gate 4: parse under the real squid binary ------------------------------
# Same image calproxy runs, in a throwaway container with no network, so this
# works even while calproxy itself is down. Nothing is written to $DEPLOYED
# until this passes.
scratch=$(mktemp -d /tmp/allowlist-validate.XXXXXX) || \
  reject "Could not create a scratch directory to validate the config."
trap 'rm -rf "$scratch"' EXIT

cp "$SQUIDCONF" "$scratch/squid.conf" 2>/dev/null && \
  cp "$WORK" "$scratch/allowed-domains.txt" 2>/dev/null || \
  reject "Could not stage the candidate config for validation."

# Outside the compose network squid cannot resolve its own FQDN and would
# FATAL on that rather than on anything Cal wrote. Pin it so the only failures
# we can see are real ones.
echo 'visible_hostname allowlist-validate' >> "$scratch/squid.conf"

parse_out=$(docker run --rm --network none \
  -v "$scratch:/etc/squid/pa:ro" \
  --entrypoint squid "$PROXY_IMAGE" \
  -k parse -f /etc/squid/pa/squid.conf 2>&1)
parse_rc=$?

if [ "$parse_rc" -ne 0 ]; then
  reject "squid rejected the candidate config (exit $parse_rc):

$(echo "$parse_out" | grep -i 'FATAL\|ERROR' | head -5)"
fi

# --- Deploy, with rollback --------------------------------------------------
cp "$DEPLOYED" "$BACKUP"
cp "$WORK" "$DEPLOYED"

added_count=$(echo "$added" | grep -cv '^[[:space:]]*$\|^[[:space:]]*#')
added_list=$(echo "$added" | grep -v '^[[:space:]]*$\|^[[:space:]]*#' | tr '\n' ' ')

rollback() {
  cp "$BACKUP" "$DEPLOYED"
  docker exec calproxy squid -k reconfigure >/dev/null 2>&1
  docker start calproxy >/dev/null 2>&1
  log "ROLLED BACK to last-good allowlist"
  notify "DEPLOY FAILED — ROLLED BACK" "$1

The last-good allowlist has been restored and calproxy told to reload. Verify with: docker ps --filter name=calproxy"
  exit 0
}

if ! docker exec calproxy squid -k reconfigure >/dev/null 2>&1; then
  rollback "squid accepted the config on parse but failed to reconfigure with it ($added_list)."
fi

# Parse and reconfigure can both succeed and squid still die on the new config,
# so confirm the proxy is actually alive before calling this applied. This is
# the check whose absence turned an eight-line mistake into a total blackout.
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' calproxy 2>/dev/null)" != "true" ]; then
  rollback "calproxy is no longer running after applying: $added_list"
fi

log "APPLIED: ${added_count} line(s): ${added_list}"
notify "APPLIED" "${added_count} new domain(s) live: ${added_list}
calproxy reconfigured and confirmed running."
