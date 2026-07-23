# Svärm

<p align="center">
  <img src="priv/static/images/swarm-hero.svg" alt="Svärm" width="280" />
</p>

**The platform where engineering teams manage their human and AI members together, with auditable cost on every ticket.**

Self-hosted, open source (MIT), built in Elixir.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.20+-6e4a7e?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-29-blue)](https://www.erlang.org)

## Why Svärm?

Your developers are already using AI coding agents: pi, Claude Code, Cursor, Copilot. They're writing code, submitting PRs, fixing bugs. But you can't see them, govern them, or prove they're worth it.

GitHub Issues feed into Svärm, which dispatches work to an agent (pi, Claude Code, etc.) using your LLM provider. The agent works in an isolated workspace and submits a PR with a cost receipt.

- **Watch agents work.** Tasks show up as cards on a board, with live logs and per-ticket cost.
- **Governance before dispatch.** Which agent, which model, which budget, approved by whom.
- **Auditable cost.** Every ticket gets a cost receipt with tokens, model, and dollar amount.

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
| [`/board`](http://localhost:4000/board) | Team board with demo tasks already moving |
| [`/dashboard`](http://localhost:4000/dashboard) | Operational overview: agent roster, cost, task distribution |
| [`/`](http://localhost:4000/) | Instance overview (tracker, agents, workflow) |
| [`/approvals`](http://localhost:4000/approvals) | First-run gates (Basic Auth: `svarm` / `svarm` in demo) |

Demo agents run without API keys. They simulate work so you can see the board in action. Click **Seed demo** on `/board` to re-seed after clearing.

> [!TIP]
> Ready for real agents? [GETTING-STARTED.md](GETTING-STARTED.md) walks through GitHub + OpenRouter + pi in about 15 minutes.

## How it works

Svärm runs a governance loop on your tickets:

1. **Reconcile** sync running work with the tracker
2. **Preflight** config, capacity, and approval checks
3. **Fetch** eligible issues (labels / states)
4. **Dispatch** agent in an isolated workspace
5. **Receipt** usage comment on the issue; human reviews the PR

Successful runs land in `review`, not `done`. Agents never merge. Every ticket gets a cost receipt with tokens, model, and dollar amount.

The poll loop follows the [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md) specification for agent orchestration.

## Architecture

```
Svarm.Orchestrator (GenServer poll loop)
    ├── Svarm.Tracker  → Local (SQLite) | GitHub
    ├── Svarm.Runner   → CLI | pi RPC
    └── Svarm.Provider → OpenRouter
             │
        Svarm.Usage.Ledger (append-only cost tracking)
```

Adapters are the extension point. Adding a new tracker, runner, or provider means one module and some config, not a fork of the orchestrator.

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

**Working now:** local board + GitHub Issues + pi/CLI agents + OpenRouter, with approvals and per-ticket cost receipts.

**Not shipped yet:** Linear/Jira trackers, multi-provider LLM abstraction, managed hosting. Don't read "adapter-ready" as "all adapters exist."

## Why self-hosted?

Your source code and API keys never leave your infrastructure. Local tracker and local models mean no cloud dependency. No SaaS middleman sees your code, keys, or token usage.
