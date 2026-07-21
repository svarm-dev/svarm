# Getting Started with Svärm

Three journeys. Pick one — don’t interleave.

| Path | Time | Needs |
|------|------|--------|
| **A** — feel the board | ~1 min | Docker or Elixir, `SECRET_KEY_BASE` only |
| **B** — real GitHub loop | ~15 min | PAT, OpenRouter, pi (Docker installs pi) |
| **C** — team hardening | after B | App auth, real approvals password, budgets |

---

## A) 60-second local feel (no API keys)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
cp .env.example .env
# set SECRET_KEY_BASE: openssl rand -base64 48

docker compose --profile demo up --build
# → http://localhost:4000/board  (auto-seeded demo tasks)
```

- Mock agents (`demo_*`) run without OpenRouter or GitHub.
- **Seed demo** stays available if you clear the board.
- Approvals UI: Basic Auth `svarm` / `svarm` by default in the demo profile.

**Local Elixir:** `mix setup && mix phx.server` → `/board` → **Seed demo**.  
(`mix svarm.demo` is a separate CLI process with its own temp DB — use Seed demo for the UI board.)

When you’re done watching cards move, go to **B** for a real issue → PR loop.

---

## B) Real loop on a toy repo

### Prerequisites

- **GitHub** account and a repo you can label issues on  
- **OpenRouter** account ([openrouter.ai](https://openrouter.ai)) — free tier is fine for a smoke test  
- **Docker** (recommended for B) **or** Elixir 1.20+ / OTP 29 ([mise](https://mise.jdx.dev))  
- **pi** on PATH for local runs (`curl -fsSL https://pi.dev/install.sh | sh`). The Docker image installs pi for you.

### 1. Environment

```bash
cp .env.example .env
```

| Variable | Required | Notes |
|----------|----------|--------|
| `SECRET_KEY_BASE` | **Yes** | `openssl rand -base64 48` |
| `APPROVALS_USER` / `APPROVALS_PASSWORD` | **Yes** for Docker `/approvals` | Any non-empty pair; demo profile defaults to `svarm`/`svarm` |
| `GITHUB_TOKEN` | For GitHub tracker | Classic PAT with `repo` scope |
| `OPENROUTER_API_KEY` | For real agents | From [openrouter.ai/keys](https://openrouter.ai/keys) |
| `SVARM_BASE_URL` | Recommended | `http://localhost:4000` so cost receipts link to the board |

Optional **GitHub App** (comments as `{slug}[bot]`): [docs/github-app.md](docs/github-app.md).

### 2. Config (auto-created)

Compose mounts **`./svarm-config/`** as a directory. First boot copies templates if files are missing — no manual `cp` required.

Edit **`svarm-config/WORKFLOW.md`** after first start (or create it first):

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

Or start from the full GitHub sample: copy `priv/workflow_template.github.md` over `svarm-config/WORKFLOW.md` and fill owner/repo.

### 3. Create a test issue

On your test repo, open an issue with label **`ai-task`**, for example:

- **Title:** `Initialize project scaffold`  
- **Body:** `Scaffold a minimal Node.js project: package.json, src/index.js hello-world HTTP server (Node http), README.`  
- **Labels:** `ai-task`

### 4. Start Svärm

```bash
docker compose up --build
# → http://localhost:4000/board
# → http://localhost:4000/  shows tracker + agent count for this install
```

Local Elixir: `mix setup && mix phx.server` (same `.env`).

### 5. Approve, then watch

Default **`approval.mode: untrusted`**: real agents will **not** run until you approve.

1. Open **http://localhost:4000/approvals** (Basic Auth from `.env`) and approve.  
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

Svärm tracks GitHub work with **labels**. Your eligibility label (e.g. `ai-task`) stays; status labels like `status: in-progress` / `status: review` are added or swapped. Success lands in **`review`**, not `done`.

---

## C) Harden for a team repo

| Step | Do this |
|------|---------|
| Bot identity | [docs/github-app.md](docs/github-app.md) — comments as `svarm[bot]` |
| Approvals | Strong `APPROVALS_USER` / `APPROVALS_PASSWORD`; keep `approval.mode: untrusted` |
| Agents | Edit `svarm-config/agents.toml` models; add CLI agents if needed |
| Smoke-only off | Never leave `approval.mode: off` on a shared repo |
| Base URL | Point `SVARM_BASE_URL` at the deployed host |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Container exits immediately | `.env` has `SECRET_KEY_BASE` |
| Config is a directory named `WORKFLOW.md` | Old file mounts — use directory mount `./svarm-config:/app/config` (current compose) and delete the bogus dirs |
| `/approvals` 404 text about APPROVALS_* | Set `APPROVALS_USER` and `APPROVALS_PASSWORD` in `.env` |
| `/approvals` 401 | Wrong Basic Auth credentials |
| Nothing happens | `docker compose logs -f` — polling / eligibility |
| Stuck before agent runs | `/approvals` — default is untrusted |
| 401/403 from GitHub | PAT `repo` scope; token in `.env` |
| No eligible issues | Issue has `ai-task`; `required_labels` matches |
| pi not found (local) | `which pi`; Docker image includes pi |
| OpenRouter errors | `OPENROUTER_API_KEY` set |
| Empty board | Path **A** (`--profile demo`) or Seed demo; path **B** needs a labeled issue |
| `mix svarm.demo` ≠ `/board` | Expected — Mix task uses a temp DB. Use Seed demo on the running server |

### Quick reset

```bash
# Docker
docker compose --profile demo down -v && docker compose --profile demo up --build

# Local
rm -rf ~/svarm_workspaces/ && mix phx.server
```

---

## Next steps

| You want to… | Do this |
|--------------|---------|
| Zero-key aha again | Path **A** / Seed demo |
| Use Claude Code | [docs/agents.md](docs/agents.md) copy-paste blocks, or edit **agents.toml** |
| Bot identity on comments | [docs/github-app.md](docs/github-app.md) |
| Other trackers (Linear/Jira) | Not in OSS yet — GitHub + local only today |
| Export costs to CSV | Not shipped yet — costs are on the board and in GitHub comments |
