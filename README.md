# Svärm

**The platform where engineering teams manage their human and AI members together — with auditable cost on every ticket.**

Self-hosted. Open source (MIT). Agent-agnostic, tracker-agnostic, provider-agnostic. Built in Elixir.

<p align="center">
  <img src="priv/static/images/swarm-hero.svg" alt="Svärm — a small flock of chevron birds" width="420" />
</p>

---

## What Svärm does

Your developers are already using AI coding agents — pi, Claude Code, Cursor, Copilot. They're writing code, submitting PRs, fixing bugs. But you can't see them, govern them, or prove they're worth it.

Svärm connects tools you already use into one governed workflow:

```
GitHub Issues → Svärm orchestrator → pi / Claude Code / any agent → PR with cost receipt
                                          ↓
                                   OpenRouter / your LLM provider
```

**Governance at the provisioning layer.** Before a single token is spent, Svärm enforces: which agent, which model, which budget, approved by whom.

**Auditable cost on every ticket.** Every completed task carries a receipt — tokens consumed, model used, dollar cost — posted as a comment on the issue.

**Agents as team members.** Agents have names and roles on the board. Work shows up as tickets, not chat history.

---

## Quick start

Full walkthrough (GitHub + pi + OpenRouter): **[GETTING-STARTED.md](GETTING-STARTED.md)**.

### Docker (recommended)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm

cp .env.example .env
# SECRET_KEY_BASE — required (no Elixir needed):
#   openssl rand -base64 48
# Add GITHUB_TOKEN and OPENROUTER_API_KEY for the real GitHub path.

mkdir -p svarm-config
cp priv/workflow_template.md svarm-config/WORKFLOW.md
cp priv/agents.toml svarm-config/agents.toml
# Edit svarm-config/WORKFLOW.md: kind: github, owner, repo, required_labels

docker compose up --build
# → http://localhost:4000/board
```

**Default safety:** `approval.mode: untrusted`. Real agents wait until you approve once at **http://localhost:4000/approvals**. Demo assignees skip the gate.

### Local (Elixir)

```bash
mise install          # optional — pins Elixir 1.20.2 / OTP 29
cp .env.example .env  # same keys as Docker
mix setup
mix phx.server
# → http://localhost:4000/board
```

### Demo (no API keys)

```bash
mix svarm.demo
# Or with the server running (dev only): open /board and use Seed demo
```

---

## Dashboard

| Route | What it shows |
|-------|---------------|
| [`/board`](http://localhost:4000/board) | Team board — status columns, live agent logs, per-ticket cost |
| [`/approvals`](http://localhost:4000/approvals) | First-run gates — approve or reject before agents touch the repo |

---

## Configuration

### `WORKFLOW.md`

Copy from `priv/workflow_template.md` to **`svarm-config/WORKFLOW.md`** (Docker) or the path in `SVARM_WORKFLOW_PATH`. Defines tracker, approvals, and the agent prompt.

### `agents.toml`

Copy from `priv/agents.toml` to **`svarm-config/agents.toml`** for Docker, or keep under `priv/` for local defaults.

```toml
[agent.default]
name = "Pi"
role = "Backend"
command = "pi"
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"

# Optional second agent (CLI harness):
# [agent.claude]
# name = "Claude"
# command = "claude"
# args = ["-p"]
# adapter = "cli"
# provider = "openrouter"
# model = "anthropic/claude-sonnet-4"
```

### Secrets

Never put keys in config files. Use `.env` (see `.env.example`):

| Variable | Purpose |
|----------|---------|
| `SECRET_KEY_BASE` | Cookie signing — **required** for Docker/prod (`openssl rand -base64 48`) |
| `GITHUB_TOKEN` | PAT mode for GitHub Issues (`repo` scope) |
| `OPENROUTER_API_KEY` | LLM access for agents / decompose |
| `SVARM_BASE_URL` | “Full run log” links in issue comments (e.g. `http://localhost:4000`) |

GitHub App identity (bot comments): [docs/github-app.md](docs/github-app.md).

---

## How it works

Svärm follows the [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md) poll loop:

1. **Reconcile** — sync running work with the tracker  
2. **Preflight** — config + capacity checks  
3. **Fetch** — eligible issues (labels / states)  
4. **Dispatch** — agent in an isolated workspace  
5. **Receipt** — usage comment on the issue; human reviews the PR  

Successful runs land in **`review`**, not `done`. Agents never merge.

---

## Architecture

```
Svarm.Orchestrator (GenServer poll loop)
    ├── Svarm.Tracker  → Local (SQLite) | GitHub
    ├── Svarm.Runner   → CLI | pi RPC
    └── Svarm.Provider → OpenRouter | …
             │
        Svarm.Usage.Ledger (append-only cost tracking)
```

New tracker, agent, or provider = one adapter module — not a fork of the orchestrator.

---

## Why self-hosted?

- **Data stays yours** — keys and source on your infrastructure  
- **Air-gapped capable** — local tracker + local models  
- **No lock-in** — change tracker, agent, or provider via config  

---

## Status

Working OSS path today: **local board + GitHub Issues + pi + OpenRouter**, with approvals and per-ticket cost receipts.

Additional trackers and managed hosting are planned; not required to try the product.

---

## Contributing

MIT licensed. Issues and PRs welcome. See [AGENTS.md](AGENTS.md) for conventions.

---

## Learn more

- [GETTING-STARTED.md](GETTING-STARTED.md) — full setup  
- [docs/github-app.md](docs/github-app.md) — bot identity  
- [Symphony SPEC](https://github.com/openai/symphony/blob/main/SPEC.md)  
- [Phoenix Framework](https://www.phoenixframework.org/)  
