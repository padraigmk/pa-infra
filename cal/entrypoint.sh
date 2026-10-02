#!/bin/bash
# Container PID 1 (runs as root; Cal itself runs as uid 1000 'cal').
# Responsibilities: in-container scheduler (R2.1) + Cal's tmux session.
set -uo pipefail

SCHEDULE=/home/cal/pa/schedule.cron

install_schedule() {
  # Cal edits schedule.cron in the pa repo (ask-gated); we (re)install it on
  # change. Scheduling is not a security boundary — a scheduled Cal has the
  # same authority as a running Cal.
  if [ -f "$SCHEDULE" ]; then
    crontab -u cal "$SCHEDULE" && SCHEDULE_MTIME=$(stat -c %Y "$SCHEDULE")
  fi
}

SCHEDULE_MTIME=""
install_schedule
cron

# A container restart kills every process, so any leftover telegram bot.pid is
# stale by definition — and container pids recycle densely, so the plugin's
# stale-poller check can SIGTERM an innocent (often its own) fresh process.
rm -f /home/cal/.claude/channels/telegram/bot.pid

CLAUDE_ARGS="${CLAUDE_ARGS:---dangerously-skip-permissions --continue}"

# The image bakes an npm-global `claude` (root-owned, in /usr/local) purely as
# a bootstrap: cal (uid 1000) can't self-update that copy. On first boot it
# installs the native build into ~/.local/bin (bind-mounted, so it survives
# image rebuilds, not just restarts); every boot after that just checks for
# an update. Never let this block starting the session — `|| true` and a
# timeout throughout, since a stale `claude` beats no session at all.
printf '%s\n' "export CLAUDE_ARGS='$CLAUDE_ARGS'" > /tmp/cal-start.sh
cat >> /tmp/cal-start.sh <<'STARTEOF'
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.cache"
LOG="$HOME/.cache/claude-install.log"
if [ "$(command -v claude 2>/dev/null)" != "$HOME/.local/bin/claude" ]; then
  echo "$(date -Is) bootstrapping native Claude Code install" >>"$LOG"
  timeout 60 /usr/local/bin/claude install latest --force >>"$LOG" 2>&1 || true
fi
timeout 60 claude update >>"$LOG" 2>&1 || true
cd /home/cal/pa
exec claude $CLAUDE_ARGS
STARTEOF
chmod +x /tmp/cal-start.sh
runuser -u cal -- tmux new-session -d -s cal /tmp/cal-start.sh

# Keep the container up while Cal's tmux session lives; re-read the schedule
# when it changes. restart: unless-stopped revives us if the session dies.
while runuser -u cal -- tmux has-session -t cal 2>/dev/null; do
  if [ -f "$SCHEDULE" ] && [ "$(stat -c %Y "$SCHEDULE")" != "$SCHEDULE_MTIME" ]; then
    install_schedule
  fi
  sleep 30
done
