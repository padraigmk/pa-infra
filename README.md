# pa-infra — the cage

Containerised runtime for Cal (the `pa` assistant). **Full reference:
[ARCHITECTURE.md](ARCHITECTURE.md)** — topology, trust boundaries, runbook,
and the sharp edges. Design rationale and audit trail live in
`pa/research/phase2-container-design.md`. This README is the quick version.

## Layout

```
compose.yml            cal container (internal network) + squid egress proxy
cal/                   Dockerfile + entrypoint (tmux session, in-container cron)
proxy/                 squid.conf + allowed-domains.txt (deny-by-default egress)
scripts/deploy.sh      root: pull deploy clone, rebuild, restart, refresh watcher
scripts/allow-domain.sh  root: manual single-domain allowlist add
host/                  allowlist watcher (systemd path unit + validator)
```

## The two copies rule

- `/home/padraig/git/pa-infra` — **working copy**, mounted read into the
  container at `/home/cal/pa-infra`. Cal edits here (ask-gated) and pushes.
- `/root/pa-infra` — **deploy clone**, root-owned, read-only deploy key.
  Only this copy is ever executed or mounted into the proxy. Cal has no
  write path to it.

Flow: Cal edits working copy → Telegram ask-approval → push. For the
allowlist, the watcher auto-applies append-only, domain-shaped changes to the
deploy copy and reloads squid. Everything else waits for a human-reviewed
`git pull` + `scripts/deploy.sh` on the deploy clone — always read
`git log -p ..origin/main` first.

## Security properties

- `calnet` is `internal: true`: the cal container has no route to the
  internet. All egress rides `HTTPS_PROXY` through squid, which allows only
  the domains in `allowed-domains.txt` on ports 80/443. WebSearch still works
  (server-side at Anthropic); WebFetch only reaches allowlisted hosts.
- uid 1000 in-container (`cal`) = `padraig` on host, so bind mounts carry no
  privilege change.
- Not mounted, no path from container: `~/.ssh`, `~/.claude` host copy,
  tailscale/docker sockets, `/etc`, `/root` (vault + pa mirrors, deploy clone).
- Scheduler (R2.1): container cron reads `pa/schedule.cron` (ask-gated file);
  entrypoint re-installs it on change. `CRON_TZ`/`TZ` Europe/London.

## Runbook

- **Deploy a change**: review, then `sudo /root/pa-infra/scripts/deploy.sh`.
- **Add an egress domain**: normally Cal appends + Telegram approval + watcher.
  Manual: `sudo /root/pa-infra/scripts/allow-domain.sh api.example.com`.
- **Test window**: stop `cal.service` before `docker compose up` — two pollers
  on one Telegram bot token conflict.
- **Rollback (first 2 weeks)**: `docker compose down` in `/root/pa-infra`,
  then `systemctl start cal.service`.
- **Restore after hostile force-push**: root mirrors (`/root/vault-mirror.git`,
  `/root/pa-mirror.git`) hold true history; push it back.
