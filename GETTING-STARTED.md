# Getting Started with Svärm

Zero-to-running with **GitHub Issues**, **pi**, and **OpenRouter**.

---

## Prerequisites

- **GitHub** account and a repo you can label issues on  
- **OpenRouter** account ([openrouter.ai](https://openrouter.ai)) — free tier is fine for a smoke test  
- **Docker** (recommended) **or** Elixir 1.20+ / OTP 29 ([mise](https://mise.jdx.dev) — versions pinned in `.mise.toml`)  
- **pi** on PATH for local runs (`curl -fsSL https://pi.dev/install.sh | sh`). The Docker image installs pi for you.

---

## 1. Clone and configure

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
```

### Environment

```bash
cp .env.example .env
```

Edit `.env`:

| Variable | Required | Notes |
|----------|----------|--------|
| `SECRET_KEY_BASE` | **Yes** (Docker/prod) | `openssl rand -base64 48` — or `mix phx.gen.secret` if you have Elixir |
| `GITHUB_TOKEN` | For GitHub tracker | Classic PAT with `repo` scope ([create token](https://github.com/settings/tokens)) |
| `OPENROUTER_API_KEY` | For real agents | From [openrouter.ai/keys](https://openrouter.ai/keys) |
| `SVARM_BASE_URL` | Recommended | `http://localhost:4000` so cost receipts link to the board |

Optional **GitHub App** (comments as `{slug}[bot]` instead of your user): [docs/github-app.md](docs/github-app.md).

mise loads `.env` for local dev. Docker Compose reads the same file.

### Config files (required for Docker)

Compose bind-mounts host paths — create them before `up`:

```bash
mkdir -p svarm-config
cp priv/workflow_template.md svarm-config/WORKFLOW.md
cp priv/agents.toml svarm-config/agents.toml
```

Edit **`svarm-config/WORKFLOW.md`**:

```yaml
tracker:
  kind: github
  owner: YOUR_GITHUB_USER_OR_ORG
  repo: YOUR_TEST_REPO
  auth: token
  api_key: $GITHUB_TOKEN
  required_labels: ["ai-task"]
```

Leave `approval.mode: untrusted` unless this is a throwaway smoke box.

### Create a test issue

On your test repo, open an issue with label **`ai-task`**, for example:

- **Title:** `Initialize project scaffold`  
- **Body:** `Scaffold a minimal Node.js project: package.json, src/index.js hello-world HTTP server (Node http), README.`  
- **Labels:** `ai-task`

---

## 2. Start Svärm

### Docker

```bash
docker compose up --build
# → http://localhost:4000/board
```

### Local Elixir

```bash
mix setup
mix phx.server
# → http://localhost:4000/board
```

No keys yet? `mix svarm.demo` exercises the loop with mock agents.

---

## 3. Approve, then watch

Default **`approval.mode: untrusted`**: pi will **not** run until you approve.

1. Open **http://localhost:4000/approvals** and approve the pending run (or the assignee).  
2. Open **http://localhost:4000/board** — logs stream on the task card.  
3. On GitHub: labels move to in-progress / review; a **cost receipt** comment appears when the run finishes.  
4. Review the PR yourself — agents do **not** merge.

Poll interval defaults to ~30s (see `polling.interval_ms` in WORKFLOW.md).

Example receipt shape:

```
✅ **Pi** completed Initialize project scaffold — $0.12 · 890 tokens · 1m 42s

| | |
|---|---|
| **Harness** | Pi |
| **Model** | … |
| **Session** | `run_…` |

→ Full run log: http://localhost:4000/board?task=…
```

### Labels and states

Svärm tracks GitHub work with **labels** (works on any repo). Your eligibility label (e.g. `ai-task`) stays; status labels like `status: in-progress` / `status: review` are added or swapped. Success lands in **`review`**, not `done`.

### Try more

- More `ai-task` issues — up to `agent.max_concurrent_agents` (default 3)  
- Local smoke only: `approval.mode: off` (turn back on for real repos)  
- Models: edit **`svarm-config/agents.toml`** (Docker) or **`priv/agents.toml`** (local defaults)  
- Claude Code: add `[agent.claude]` with `adapter = "cli"`, `command = "claude"`

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Container exits immediately | `.env` has `SECRET_KEY_BASE`; `svarm-config/WORKFLOW.md` and `agents.toml` exist on the host |
| Nothing happens | Logs: `docker compose logs -f` — look for polling / eligibility |
| Stuck before agent runs | **http://localhost:4000/approvals** — default is untrusted |
| 401/403 from GitHub | PAT `repo` scope; token in `.env` (Compose loads it) |
| No eligible issues | Issue has `ai-task`; `required_labels` matches exactly |
| pi not found (local) | `which pi`; Docker rebuilds include pi |
| OpenRouter errors | `OPENROUTER_API_KEY` set; free tier may need credits |
| No cost comment | `SVARM_BASE_URL`; logs for posted run summary |
| Empty board | Open **`/board`**, not only `/`. Dev: Seed demo for local kanban |

### Quick reset

```bash
# Docker
docker compose down -v && docker compose up --build

# Local
rm -rf ~/svarm_workspaces/ && mix phx.server
```

---

## Next steps

| You want to… | Do this |
|--------------|---------|
| Use Claude Code | Edit **agents.toml** (`svarm-config/` in Docker, else `priv/`): `adapter = "cli"`, `command = "claude"` |
| Add agents | New `[agent.name]` sections in the same agents.toml path you mount/load |
| Bot identity on comments | [docs/github-app.md](docs/github-app.md) |
| See per-ticket cost | `/board` → select a task |
| Other trackers (Linear/Jira) | Not in OSS yet — GitHub + local only today |
| Export costs to CSV | Not shipped yet — costs are on the board and in GitHub comments |
