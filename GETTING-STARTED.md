# Getting Started with Svärm

A zero-to-running guide for GitHub Issues, pi, and OpenRouter.

---

## Prerequisites

- **GitHub account** with a repo you can create issues on
- **OpenRouter account** ([openrouter.ai](https://openrouter.ai)) — free tier works for testing
- **pi** on PATH (`which pi`). Install: `curl -fsSL https://pi.dev/install.sh | sh`
- **Docker** (recommended) or **Elixir** 1.20+ / OTP 29 ([mise](https://mise.jdx.dev) recommended — `.mise.toml` pins versions)

---

## 1. Clone and configure

```bash
git clone https://github.com/YOUR_ORG/svarm.git
cd svarm
```

### API keys

```bash
cp .env.example .env
# Edit .env — add your GITHUB_TOKEN, OPENROUTER_API_KEY, and SECRET_KEY_BASE
#   Generate a key: mix phx.gen.secret  (or any 64+ char random string)
# SVARM_BASE_URL is pre-filled to http://localhost:4000
```

- `GITHUB_TOKEN` — [classic PAT](https://github.com/settings/tokens) with `repo` scope (default `auth: token`)
- **or GitHub App** (recommended): set `auth: app` in WORKFLOW and `SVARM_GITHUB_APP_ID` + `SVARM_GITHUB_APP_KEY_PATH` — see [docs/github-app.md](docs/github-app.md). Comments appear as `{app-slug}[bot]`. App name is free (e.g. `svarm-bot` if `svarm` is taken).
- `OPENROUTER_API_KEY` — from [openrouter.ai/keys](https://openrouter.ai/keys)
- `SVARM_BASE_URL` — enables the "Full run log" link in cost receipts

mise auto-loads `.env` for local dev. Docker Compose also reads it. No shell exports needed.

### Create config files

```bash
mkdir -p svarm-config

# WORKFLOW.md — edit owner/repo to match your test repo
cp priv/workflow_template.md svarm-config/WORKFLOW.md
# Edit svarm-config/WORKFLOW.md: set owner, repo, kind: github, required_labels

# agents.toml — defaults work, edit if you want custom agents
cp priv/agents.toml svarm-config/agents.toml
```

### Create a test repo on GitHub

Create a repo (e.g. `svarm-test`). Add one issue with label `ai-task`:
- Title: `Initialize project scaffold`
- Body: `Scaffold a minimal Node.js project: create package.json, add a src/index.js with a hello-world HTTP server using Node's built-in http module, and write a README.md describing the project.`
- Labels: `ai-task`

---

## 2. Start Svärm

### Docker (recommended)

```bash
docker compose up --build
# → http://localhost:4000
```

### Local (if you have Elixir)

```bash
mix setup
mix phx.server
# → http://localhost:4000
```

Verify with the demo (no API keys needed): `mix svarm.demo`

---

## 3. Watch it work

Svärm polls every 15 seconds. Within 30 seconds of starting:

1. **Claim** — Svärm adds `claimed` and `status: in-progress` labels. The `ai-task` label stays.
2. **Run** — pi spawns in an isolated workspace under `~/svarm_workspaces/`
3. **Complete** — pi makes changes, commits, and exits. Svärm posts a cost receipt comment:

```
✅ **Pi** completed Initialize project scaffold — $0.12 · 890 tokens · 1m 42s

| | |
|---|---|
| **Harness** | Pi |
| **Model** | claude-sonnet-4 |
| **Session** | `run_abc123def` |

→ Full run log: http://localhost:4000/board?task=sva_abc123
```

Open http://localhost:4000/board to watch live streaming logs, per-ticket costs, and agent status.

### Configuration reference

| Field | Purpose |
|-------|---------|
| `tracker.kind: github` | Switches from local SQLite to GitHub Issues |
| `required_labels` | Only issues with these labels are eligible for dispatch |
| `approval.mode: untrusted` | Default — human must approve before real agents run (`default` / `demo_*` skip) |
| `approval.mode: off` | Skips human gate (local smoke only; turn back on for real repos) |
| `polling.interval_ms` | How often Svärm checks for new work |
| Success status | Successful runs land in **`review`**, not `done` — human PR review + merge |

Svärm uses **labels** to track state on GitHub (rather than project board status fields — simpler, works on any repo). Status labels like `status: in-progress` and `status: review` are added and swapped. Your `required_labels` (e.g. `ai-task`) stay on the issue throughout. Agents never auto-merge.

### Try more things

- **Create more work** — add issues with `ai-task` label. Svärm dispatches up to 3 concurrently.
- **Skip approval (local only)** — set `approval.mode: off` in WORKFLOW.md, restart. Prefer `untrusted` for any shared/production repo.
- **Paid models** — change `model` in agents.toml to `anthropic/claude-sonnet-4` or `openai/gpt-4o`.
- **Claude Code** — add `[agent.claude]` section to agents.toml with `adapter: "cli"`, `command: "claude"`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Nothing happens | Check logs (`docker compose logs` or terminal). Should show `"orchestrator: polling..."` |
| 401/403 errors | `GITHUB_TOKEN` is exported in shell (Docker reads from host env) and has `repo` scope |
| No eligible issues | GitHub issue has `ai-task` label. `required_labels` in WORKFLOW.md matches exactly |
| pi not found | Check pi is installed: `which pi`. For Docker: pi is built into the image — rebuild with `docker compose up --build` |
| OpenRouter errors | `OPENROUTER_API_KEY` is set. Free tier may need credits loaded |
| No cost comment | `SVARM_BASE_URL` is set. Check logs for `"github: posted run summary"` |
| Dashboard empty | Visit http://localhost:4000/board (not just `/`). Click "Seed demo" for local kanban |

### Quick reset

```bash
# Docker
docker compose down -v && docker compose up --build

# Local
rm -rf ~/svarm_workspaces/ && mix phx.server
```

---

## Next steps

| You want to... | What to read |
|----------------|-------------|
| Use Claude Code instead of pi | Edit `priv/agents.toml`, set `adapter: "cli"`, `command: "claude"` |
| Add more agents | Add `[agent.name]` sections to agents.toml |
| Require human approval | Default in template (`untrusted`); set `off` only for local smoke |
| Change polling frequency | `polling.interval_ms: 60000` (1 minute) |
| See per-agent costs | Visit `/board`, select a task card — cost breakdown in the run panel |
| Export costs to CSV | Planned (step B12). For now, costs are on the board and in GitHub comments |
| Use Jira or Linear | Not in OSS v1 — trackers beyond GitHub/local are planned |
