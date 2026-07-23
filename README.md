# Svärm

*Pronounced "svˈɛrm" (rhymes with "farm"). Swedish for "swarm."*

The platform where engineering teams manage their human and AI members together, with auditable cost on every ticket.

Self-hosted, open source (MIT), built in Elixir. Working today: local board + GitHub Issues + pi + OpenRouter.

<p align="center">
  <img src="priv/static/images/swarm-hero.svg" alt="Svärm" width="280" />
</p>

---

## What Svärm does

Your developers are already using AI coding agents: pi, Claude Code, Cursor, Copilot. They're writing code, submitting PRs, fixing bugs. But you can't see them, govern them, or prove they're worth it.

Svärm connects tools you already use into one governed workflow:

```
GitHub Issues → Svärm orchestrator → pi / Claude Code / any agent → PR with cost receipt
                                          ↓
                                   OpenRouter / your LLM provider
```

It solves two problems. First, agents are invisible team members. They read issues, edit code, run tests, submit PRs, but no tool treats them as team members. Svärm gives them identity on a shared board, routes work to them by skill, and tracks their output alongside human work. Second, AI spend is ungoverned. Enterprises burn $500–$2,000 per engineer per month on AI tools with zero per-ticket visibility. Svärm enforces governance at the provisioning layer, controlling which agent, which model, which budget, before tokens flow. Every ticket gets a cost receipt.

---

## Status

Working now: local board + GitHub Issues + pi/CLI agents + OpenRouter, with approvals and per-ticket cost receipts.

Not shipped yet: Linear/Jira trackers, multi-provider LLM abstraction, managed hosting. Don't read "adapter-ready" as "all adapters exist."

First public release: v0.1.1. See [docs/release.md](docs/release.md).

---

## Quick start

### Docker (3 commands)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
docker compose --profile demo up --build
```

SECRET_KEY_BASE is auto-generated on first run. Set it in `.env` for persistence across restarts.

### Elixir (if you have 1.20+ / OTP 29)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
cp .env.example .env
# set SECRET_KEY_BASE: openssl rand -base64 48
mix setup
mix phx.server
```

### 3. Open the board

- [/board](http://localhost:4000/board): team board with demo tasks already moving
- [/](http://localhost:4000/): instance overview (tracker, agents, workflow)
- [/approvals](http://localhost:4000/approvals): first-run gates (Basic Auth: `svarm` / `svarm` in demo)

Demo agents run without API keys. They simulate work so you can see the board in action. Click **Seed demo** on `/board` to re-seed after clearing.

Ready for real agents? [GETTING-STARTED.md](GETTING-STARTED.md) walks through GitHub + OpenRouter + pi in about 15 minutes.

---

## How it works

Svärm runs a governance loop on your tickets:

1. Reconcile: sync running work with the tracker
2. Preflight: config, capacity, and approval checks
3. Fetch: eligible issues (labels / states)
4. Dispatch: agent in an isolated workspace
5. Receipt: usage comment on the issue; human reviews the PR

Successful runs land in `review`, not `done`. Agents never merge. Every ticket gets a cost receipt with tokens, model, and dollar amount.

The poll loop follows the [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md) specification for agent orchestration.

---

## Architecture

```
Svarm.Orchestrator (GenServer poll loop)
    ├── Svarm.Tracker  → Local (SQLite) | GitHub   (Linear/Jira: not shipped)
    ├── Svarm.Runner   → CLI | pi RPC
    └── Svarm.Provider → OpenRouter
             │
        Svarm.Usage.Ledger (append-only cost tracking)
```

Adapters are the extension point. Adding a new tracker, runner, or provider means one module and some config, not a fork of the orchestrator.

---

## Configuration

Docker mounts `./svarm-config/` as a directory. On first boot, missing files are copied from templates. You don't need to mkdir or cp anything first.

| File | Role |
|------|------|
| `svarm-config/WORKFLOW.md` | Tracker, approvals mode, agent prompt |
| `svarm-config/agents.toml` | Agent commands, adapters, models |

Full walkthrough: [GETTING-STARTED.md](GETTING-STARTED.md)

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

---

## Why self-hosted?

Your source code and API keys never leave your infrastructure. Local tracker and local models mean no cloud dependency. No SaaS middleman sees your code, keys, or token usage. You swap tracker, agent, and provider via files, not vendor portals.

---

## Contributing

MIT licensed. Issues and PRs welcome.

- Try it: [GETTING-STARTED.md](GETTING-STARTED.md)
- Agent configs: [docs/agents.md](docs/agents.md)
- Developing this repo: [AGENTS.md](AGENTS.md)
