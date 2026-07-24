## Svärm v0.1.1 — first public try path

Self-hosted control plane for coding agents: tickets on a board, approvals, cost on every run.

### Try in ~1 minute (no API keys)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
cp .env.example .env
# set SECRET_KEY_BASE: openssl rand -base64 48
docker compose --profile demo up --build
# → http://localhost:4000/board
```

### Shipped in this release

- Docker **demo profile** — auto-seed board, Seed demo button
- `APPROVALS_USER` / `APPROVALS_PASSWORD` for `/approvals` in Docker
- Directory config mount + first-boot templates (no file-mount footguns)
- Instance status on `/`, first-run checklist on empty board, `GET /health`
- README journeys: A demo · B GitHub loop · C harden
- Orchestrator stays up when a tracker is rate-limited or unreachable
- Compose **app** / **demo** profiles no longer fight over port 4000

### Working surface today

Local board + **GitHub Issues** + **pi/CLI** + **OpenRouter**. Linear/Jira and managed hosting are not in this tag.

### Docs

- [GETTING-STARTED.md](https://github.com/svarm-dev/svarm/blob/v0.1.1/GETTING-STARTED.md)
- [CHANGELOG](https://github.com/svarm-dev/svarm/blob/v0.1.1/CHANGELOG.md)
