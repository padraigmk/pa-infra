#!/bin/bash
# Nightly ff-only fetch into a root-owned history mirror — run from root's
# crontab, from the DEPLOY clone only (/root/pa-infra/host/), never Cal's
# working copy.
#
#   mirror-fetch.sh <mirror.git> <source-repo> <log>
#
# A refused fetch is the whole point of the mirror: it means the source's
# history no longer contains the mirror's (a rewrite — hostile, or a rebase).
# Until 2026-11-01 that refusal only went to a log nobody read, and the pa
# mirror sat frozen for 83 days. Now it alerts.
set -uo pipefail

MIRROR="$1" SRC="$2" LOG="$3"
NAME=$(basename "$MIRROR" .git)
TG_ENV=/home/padraig/cal-home/.claude/channels/telegram/.env
TG_CHAT=8502631426

notify() {
  local token
  [ -r "$TG_ENV" ] || return 0
  # \042 = double quote, \047 = single quote. Never echoed or logged.
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" | cut -d= -f2- | tr -d '\042\047')
  [ -n "$token" ] || return 0
  curl -s -m 15 -o /dev/null \
    -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$TG_CHAT" \
    --data-urlencode "text=🪞 ${NAME} — $1"
}

out=$(git --git-dir="$MIRROR" -c safe.directory="$SRC" fetch origin master:master 2>&1)
rc=$?
{ echo "$(date -Is) exit=$rc"; [ -n "$out" ] && echo "$out"; } >> "$LOG"

[ "$rc" -eq 0 ] && exit 0

if grep -q 'non-fast-forward' <<<"$out"; then
  notify "HISTORY REWRITE REFUSED. The mirror kept its history; origin/master shows what the source now has.
Inspect: git -C $MIRROR log --oneline master..origin/master
Patch-equivalent (a rebase)? git -C $MIRROR cherry origin/master master  — all '-' = nothing lost.
If legit: tag master, then update-ref master to origin/master. See pa-infra ARCHITECTURE.md."
else
  notify "FETCH FAILED (exit $rc). See $LOG."
fi
exit "$rc"
