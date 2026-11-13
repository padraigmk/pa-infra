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

# Fail safe, not open: if compose ever stops passing CLAUDE_ARGS, fall back to
# auto mode (deny/ask rules hold) rather than skipping permissions entirely.
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode auto --continue}"

# Claude Code is the native build in ~/.local/bin (bind-mounted, so it
# survives image rebuilds, and cal-owned, so it can self-update). A fresh home
# gets it from the official installer; every boot checks for an update. Never
# let this block starting the session — `|| true` and a timeout throughout.
printf '%s\n' "export CLAUDE_ARGS='$CLAUDE_ARGS'" > /tmp/cal-start.sh
cat >> /tmp/cal-start.sh <<'STARTEOF'
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.cache"
LOG="$HOME/.cache/claude-install.log"
if [ ! -x "$HOME/.local/bin/claude" ]; then
  echo "$(date -Is) bootstrapping native Claude Code install" >>"$LOG"
  timeout 120 bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >>"$LOG" 2>&1 || true
fi
timeout 60 claude update >>"$LOG" 2>&1 || true
cd /home/cal/pa
exec claude $CLAUDE_ARGS
STARTEOF
chmod +x /tmp/cal-start.sh
runuser -u cal -- tmux new-session -d -s cal /tmp/cal-start.sh

# Voice/web server (pa/voice/server.py, :8765 — the phone reaches it via the
# voicegw relay + `tailscale serve`). It used to be started by hand, so every
# restart — now including unattended-upgrade reboots — left voice down. Safe
# to start before claude: it checks the calweb channel per turn and falls back
# to tmux. Never block boot on it.
if [ -f /home/cal/pa/voice/server.py ]; then
  runuser -u cal -- bash -c 'cd /home/cal/pa && nohup uv run voice/server.py --host 0.0.0.0 >> /tmp/voice-server.log 2>&1 &' || true
fi

# --dangerously-load-development-channels asks for confirmation at every
# launch. Accept it only when the dev channels it lists are exactly
# our own (server:calweb, with or without server:agent-ui); anything else
# stays on screen for a human. "1"
# picks option 1; Enter is a fallback in case the number only moved focus.
# Gives up after 3 min (the update check above can take 60s first).
(
  pane() { runuser -u cal -- tmux capture-pane -p -t cal:0 2>/dev/null; }
  for _ in $(seq 90); do
    sleep 2
    p=$(pane) || continue
    grep -q "Loading development channels" <<<"$p" || continue
    chans=$(grep -o 'server:[A-Za-z0-9_.-]*' <<<"$p" | sort -u | tr '\n' ' ')
    if [ "$chans" != "server:calweb " ] && [ "$chans" != "server:agent-ui server:calweb " ]; then
      echo "dev-channels dialog lists '$chans' — not auto-accepting"
      break
    fi
    runuser -u cal -- tmux send-keys -t cal:0 1
    sleep 2
    grep -q "Loading development channels" <<<"$(pane)" \
      && runuser -u cal -- tmux send-keys -t cal:0 Enter
    echo "dev-channels dialog auto-accepted ($chans)"
    break
  done
) &

# Keep the container up while Cal's tmux session lives; re-read the schedule
# when it changes. restart: unless-stopped revives us if the session dies.
while runuser -u cal -- tmux has-session -t cal 2>/dev/null; do
  if [ -f "$SCHEDULE" ] && [ "$(stat -c %Y "$SCHEDULE")" != "$SCHEDULE_MTIME" ]; then
    install_schedule
  fi
  sleep 30
done
