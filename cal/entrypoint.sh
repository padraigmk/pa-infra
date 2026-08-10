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
runuser -u cal -- tmux new-session -d -s cal \
  "cd /home/cal/pa && claude $CLAUDE_ARGS"

# Keep the container up while Cal's tmux session lives; re-read the schedule
# when it changes. restart: unless-stopped revives us if the session dies.
while runuser -u cal -- tmux has-session -t cal 2>/dev/null; do
  if [ -f "$SCHEDULE" ] && [ "$(stat -c %Y "$SCHEDULE")" != "$SCHEDULE_MTIME" ]; then
    install_schedule
  fi
  sleep 30
done
