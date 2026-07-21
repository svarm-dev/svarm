# Svärm

**The platform where engineering teams manage their human and AI members together — with auditable cost on every ticket.**

Self-hosted. Open source (MIT). Agent-agnostic, tracker-agnostic, provider-agnostic. Built in Elixir.

---

## What Svärm does

Your developers are already using AI coding agents — pi, Claude Code, Cursor, Copilot. They're writing code, submitting PRs, fixing bugs. But you can't see them, govern them, or prove they're worth it.

Svärm connects your existing tools into one governed workflow:

```
GitHub Issues → Svärm orchestrator → pi / Claude Code / any agent → PR with cost receipt
       ↑                                  ↓
  Linear / Jira (Pro)              OpenRouter / direct API / any provider
```

**Governance at the provisioning layer.** Before a single token is spent, Svärm enforces: which agent, which model, which budget, approved by whom.

**Auditable cost on every ticket.** Every completed task carries a receipt — tokens consumed, model used, dollar cost — posted as a comment on the issue.

**Agents as team members.** Agents have names, roles, and track records. They communicate through tickets. The dashboard shows the blended team at work.

---

## Quick start

For a complete walkthrough with GitHub + pi + OpenRouter, see [GETTING-STARTED.md](GETTING-STARTED.md).

```bash
docker compose up
# → http://localhost:4000
```

### Local

```bash
mise install          # optional — pins Elixir 1.20.2 / OTP 29
mix setup
mix phx.server
# → http://localhost:4000
```

### Demo (no API keys needed)

```bash
mix svarm.demo          # isolated CLI demo with mock LLM
# Or with the web dashboard running:
# POST /dev/demo/seed   (dev mode only)
```

---

## Dashboard

| Route | What it shows |
|-------|---------------|
| `/board` | Kanban board — columns per status, real-time updates via PubSub, streaming agent logs |
| `/approvals` | Human-in-the-loop gates — approve or reject agent work before it reaches the repo |

---

## Configuration

### `WORKFLOW.md`

Place at repo root (or copy from `priv/workflow_template.md`). Defines:

- **Tracker** — which issue tracker, states, labels, polling
- **Approvals** — trust mode, exempt assignees
- **Prompts** — template rendered for each agent run

### `priv/agents.toml`

Define your coding agents:

```toml
[agents.pi]
name = "Pi"
command = "pi"
args = ["--mode", "rpc"]
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"

[agents.claude]
name = "Claude"
command = "claude"
args = ["-p"]
adapter = "cli"
provider = "openrouter"
model = "anthropic/claude-sonnet-4"
```

### Provider secrets

API keys via environment variables — never in config files:

```bash
export OPENROUTER_API_KEY=sk-or-...
export GITHUB_TOKEN=ghp_...
```

---

## How it works

Svärm implements the [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md) poll loop:

1. **Reconcile** — sync running tasks with tracker state
2. **Preflight** — validate WORKFLOW.md config, check agent availability
3. **Fetch** — find eligible issues from the tracker
4. **Dispatch** — assign to agent, spawn in isolated workspace
5. **Repeat** — on completion, post usage receipt to issue, fetch next

Agents run in per-task workspaces under `~/svarm_workspaces` (configurable). Each workspace is isolated — no cross-task file conflicts.

---

## Architecture

```
Svarm.Orchestrator (GenServer poll loop)
    ├── Svarm.Tracker (behaviour)
    │   ├── Tracker.Local (SQLite — default)
    │   └── Tracker.GitHub (v1)
    ├── Svarm.Runner (behaviour)
    │   ├── Runner.Cli (any command)
    │   └── Runner.Pi.Rpc (pi bidirectional — v1)
    └── Svarm.Provider (resolver)
        ├── OpenRouter (v1)
        └── Direct API / custom endpoints
             │
        Svarm.Usage.Ledger (append-only cost tracking)
```

Everything is pluggable. Adding a new tracker, agent, or provider = one adapter module, not a fork of the orchestrator.

---

## Why self-hosted?

- **Digital sovereignty** — data and API keys never leave your infrastructure. No US CLOUD Act exposure. CADA-ready for European enterprises.
- **Zero data retention** — you control what's stored and for how long
- **Air-gapped deployment** — works without internet access (local tracker + local models)
- **No vendor lock-in** — switch trackers, agents, or providers by changing config, not rewriting integrations

---

## Status

**MVP shipped** — local kanban, orchestrator poll loop, WORKFLOW.md, approvals, LiveView dashboard.

**v1 path** — GitHub tracker, pi RPC adapter, OpenRouter provider, usage ledger, GitHub App bot identity.

---

## Contributing

MIT licensed. Issues and PRs welcome. See [AGENTS.md](AGENTS.md) for conventions.

---

## Learn more

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Symphony SPEC](https://github.com/openai/symphony/blob/main/SPEC.md)
- [Workday Agent System of Record](https://www.workday.com/en-us/artificial-intelligence/agent-system-of-record.html) — where the industry is heading
