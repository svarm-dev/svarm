# Svärm

<p align="center">
  <img src="priv/static/images/swarm-hero.svg" alt="Svärm" width="280" />
</p>

**Governed coding agents on your tickets: identity, live board, approvals, and cost on every run.**

Self-hosted, open source (MIT), built in Elixir.

[![CI](https://github.com/svarm-dev/svarm/actions/workflows/ci.yml/badge.svg)](https://github.com/svarm-dev/svarm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.20+-6e4a7e?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-29-blue)](https://www.erlang.org)

## Why Svärm?

Your team already uses AI coding agents (pi, Claude Code, Cursor, Copilot). They open PRs and touch real code. Most of that work is hard to see, hard to approve, and hard to cost.

Svärm pulls work from GitHub Issues (or a local board), runs an agent in an isolated workspace, and leaves a PR plus a cost receipt for a human to review.

- **Watch agents work.** Cards on a board with live logs and per-ticket cost.
- **Gate before dispatch.** Which agent, which model, approved by whom.
- **Cost on the ticket.** Tokens, model, and dollar amount on the run.

## Quick start

### Docker (3 commands)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
docker compose --profile demo up --build
```

`SECRET_KEY_BASE` is auto-generated on first run. Set it in `.env` for persistence across restarts.

### Elixir (if you have 1.20+ / OTP 29)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
cp .env.example .env
# set SECRET_KEY_BASE: openssl rand -base64 48
mix setup
mix phx.server
```

### Open the board

| Route | What it shows |
|-------|---------------|
| [`/board`](http://localhost:4000/board) | Agent board with demo tasks already moving |
| [`/dashboard`](http://localhost:4000/dashboard) | Operational overview: agent roster, cost, task distribution |
| [`/`](http://localhost:4000/) | Instance overview (tracker, agents, workflow) |
| [`/approvals`](http://localhost:4000/approvals) | First-run gates (Basic Auth: `svarm` / `svarm` in demo) |

Demo agents run without API keys. They simulate work so you can see the board in action. Click **Seed demo** on `/board` to re-seed after clearing.

## Screenshots

<p align="center">
  <img src="docs/screenshots/board-seeded.png" alt="Svärm board with tasks and per-ticket cost" width="900" />
</p>

<p align="center">
  <img src="docs/screenshots/card-running.png" alt="Selected task with cost breakdown" width="900" />
</p>

<p align="center">
  <img src="docs/screenshots/dashboard.png" alt="Dashboard with agent roster and cost" width="900" />
</p>

More captures under [`docs/screenshots/`](docs/screenshots/).

> [!TIP]
> Ready for real agents? [GETTING-STARTED.md](GETTING-STARTED.md) walks through GitHub + OpenRouter + pi in about 15 minutes.

## How it works

Svärm polls your tracker and runs a short loop:

1. **Reconcile** sync running work with the tracker
2. **Preflight** config, capacity, and approval checks
3. **Fetch** eligible issues (labels / states)
4. **Dispatch** agent in an isolated workspace
5. **Receipt** usage comment on the issue; human reviews the PR

Successful runs land in `review`, not `done`. Agents never merge. Each finished run can post a cost receipt (tokens, model, dollars) on the issue.

The poll loop follows the [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md) agent-orchestration shape (reconcile, workspace isolation, WORKFLOW.md).

## Architecture

```
Svarm.Orchestrator (GenServer poll loop)
    ├── Svarm.Tracker  → Local (SQLite) | GitHub
    ├── Svarm.Runner   → CLI | pi RPC
    └── Svarm.Provider → OpenRouter
             │
        Svarm.Usage.Ledger (append-only cost tracking)
```

Adapters are the extension point. A new tracker, runner, or provider is one module plus config, not a fork of the orchestrator. Shipped adapters are listed under Status.

## Configuration

Docker mounts `./svarm-config/` as a directory. On first boot, missing files are copied from templates. You don't need to mkdir or cp anything first.

| File | Role |
|------|------|
| `svarm-config/WORKFLOW.md` | Tracker, approvals mode, agent prompt |
| `svarm-config/agents.toml` | Agent commands, adapters, models |

<details>
<summary>Environment variables</summary>

| Variable | Purpose |
|----------|---------|
| `SECRET_KEY_BASE` | Cookie signing, required for Docker/prod (`openssl rand -base64 48`) |
| `APPROVALS_USER` / `APPROVALS_PASSWORD` | Basic Auth for `/approvals` in Docker/prod |
| `GITHUB_TOKEN` | PAT for GitHub Issues (`repo` scope) |
| `OPENROUTER_API_KEY` | LLM access for agents |
| `SVARM_BASE_URL` | Links in issue comments (e.g. `http://localhost:4000`) |
| `SVARM_SEED_DEMO=1` | Boot-seed mock tasks when board is empty |

GitHub App identity (bot comments): [docs/github-app.md](docs/github-app.md).
</details>

## Documentation

- [GETTING-STARTED.md](GETTING-STARTED.md) full setup walkthrough
- [docs/agents.md](docs/agents.md) agent.toml copy-paste blocks
- [AGENTS.md](AGENTS.md) for coding agents editing this repo

## Status

**Working now:** local board + GitHub Issues + pi/CLI agents + OpenRouter, with approvals and per-ticket cost receipts. Humans show up as approvers and PR reviewers, not as a separate people roster.

**Not shipped yet:** Linear/Jira trackers, multi-provider UI, managed hosting, in-app setup wizard. "Adapter-ready" means the behaviours exist; it does not mean every adapter is built.

## Why self-hosted?

Source code and API keys stay on your machines. You can run a local tracker and keep LLM traffic on whatever provider you configure. There is no Svärm cloud in the middle of that path.
