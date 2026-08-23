# Getting Started with Svärm

Three journeys. Pick one; do not interleave.

| Journey | Time | Needs |
|---------|------|-------|
| **Feel the board** — local board, no tracker | ~1 min | Docker (`--profile demo` auto-seeds) or Elixir + Seed demo; no API keys |
| **Real tracker loop** — external issue tracker (GitHub today) | ~15 min | PAT, OpenRouter, pi (Docker installs pi) |
| **Team hardening** | after the real loop | GitHub App auth + strong APPROVALS_*; optional budget caps |

---

## Feel the board: 60-second local demo (no API keys)

```bash
git clone https://github.com/svarm-dev/svarm.git
cd svarm
docker compose --profile demo up --build
# → http://localhost:4000/board  (auto-seeded demo tasks)
```

`.env` is optional for the demo. Entrypoint generates `SECRET_KEY_BASE` if unset; put one in `.env` if you want it stable across restarts.


- Mock agents (`demo_*`) run without OpenRouter or GitHub.
- **Seed demo** stays available if you clear the board.
- Approvals UI: Basic Auth `svarm` / `svarm` by default in the demo profile.
- Ops overview: [`/dashboard`](http://localhost:4000/dashboard) — Outcomes ROI (merge rate / `$/merged` over the Spend window), 24h wall-clock cost per agent from the usage ledger (`est.` when any row is estimated), and retry share (`n/a` unless the tracker records attempts).

**Local Elixir:** `mix setup && mix phx.server` → `/board` → **Seed demo**.  
(`mix svarm.demo` is a separate CLI process with its own temp DB; use Seed demo for the UI board.)

When you’re done watching cards move, go to the **real tracker loop** for a real issue → PR loop.

**Optional UI setup:** after demo, open `/setup` to store OpenRouter + GitHub PAT + default model in the app DB (encrypted). File/env config still works when Settings is empty. In Docker, `/setup` uses the same Basic Auth as `/approvals`.

---

## Real tracker loop on a toy repo

Connect an external issue tracker — GitHub today, more planned — and watch tickets become PRs.

### Prerequisites

- **GitHub** account and a repo you can label issues on  
- **OpenRouter** account ([openrouter.ai](https://openrouter.ai)); free tier is fine for a smoke test  
- **Docker** (recommended for B) **or** Elixir 1.20+ / OTP 29 ([mise](https://mise.jdx.dev))  
- **pi** on PATH for local runs (`curl -fsSL https://pi.dev/install.sh | sh`). The Docker image installs pi for you.

### 1. Environment

```bash
cp .env.example .env
```

| Variable | Required | Notes |
|----------|----------|--------|
| `SECRET_KEY_BASE` | **Yes** | `openssl rand -base64 48` |
| `APPROVALS_USER` / `APPROVALS_PASSWORD` | **Yes** for Docker/prod (UI + board mutations) | Strong unique pair in `.env` (`.env.example` leaves them empty). **Demo** compose profile still defaults to `svarm`/`svarm` for the zero-key demo only. Without credentials, production high-trust board mutations (approve/reject/mark-done/answer/steer/overage) fail closed |
| `GITHUB_TOKEN` | For GitHub tracker | Classic PAT with `repo` scope |
| `OPENROUTER_API_KEY` | For real agents | From [openrouter.ai/keys](https://openrouter.ai/keys) |
| `SVARM_BASE_URL` | Optional | Public board origin (e.g. `http://localhost:4000`). Used for GitHub comment console links **only** when the opt-in below is on |
| `SVARM_COMMENT_CONSOLE_LINKS` | Optional, default **off** | Set `true` to embed `/board?task=…&attach=1` in GitHub run comments. Board **reads** are unauthenticated — anyone who can read the issue can open the console. Leave unset on public repos (see [SECURITY.md](SECURITY.md)) |
| `PHX_SECURE_COOKIES` | For plain-HTTP local `app` only | Prod/compose **app** defaults Secure (`true`). On `http://localhost` with `--profile app`, set `PHX_SECURE_COOKIES=false` in `.env` so sessions work. Demo profile sets this for you. |

Optional **GitHub App** (comments as `{slug}[bot]`): [docs/github-app.md](docs/github-app.md).

### 2. Config (auto-created)

Compose mounts **`./svarm-config/`** as a directory. First boot copies templates if files are missing. No manual `cp` required.

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
docker compose --profile app up --build
# → http://localhost:4000/board
# → http://localhost:4000/  shows tracker + agent count for this install
```

Local Elixir: `mix setup && mix phx.server` (same `.env`).

### 5. Approve, then watch

Default **`approval.mode: untrusted`**: real agents will **not** run until you approve.

1. Open **http://localhost:4000/approvals** (Basic Auth from `.env`) and approve.  
2. Open **http://localhost:4000/board**. Logs stream on the task card.  
3. On GitHub: labels move to in-progress / review; a **cost receipt** comment appears when the run finishes.  
4. Open the card in **`review`**: the **Evidence** pack shows PR (when known), attempts, agent/model, cost (estimated labeled), age, and a **CI** chip (`pass` / `fail` / `pending` / `unknown`, or **N/A** on the local tracker). It is **informational** — Svärm does not merge; you still merge on GitHub (or **Mark done** on the local board). Review-column cards also show glanceable **PR** / **no PR** (and CI when known).  
5. Review the PR yourself. Agents do **not** merge.

Poll interval defaults to ~30s (see `polling.interval_ms` in WORKFLOW.md).

Pi RPC runs default to a **45-minute wall-clock** timeout (streaming does not extend it); orchestrator stall is the same duration (WORKFLOW `agent.stall_timeout_ms`). Keep run timeout ≤ stall so abort→kill runs before stall. See [docs/agents.md](docs/agents.md#pi-rpc-profile-default-for-the-real-tracker-loop).

Example receipt shape (cost / harness / session stay; the board URL does **not** unless you set `SVARM_COMMENT_CONSOLE_LINKS=true`):

```
✅ **Pi** completed Initialize project scaffold · $0.12 · 890 tokens · 1m 42s

| | |
|---|---|
| **Harness** | Pi |
| **Model** | … |
| **Session** | `run_…` |
```

With the opt-in, comments also get `→ Full run log: {SVARM_BASE_URL}/board?task=…&attach=1`. Default Compose / prod leave that off.

### Labels and states

Svärm tracks GitHub work with **labels**. Your eligibility label (e.g. `ai-task`) stays; status labels like `status: in-progress` / `status: pending-approval` / `status: review` are added or swapped. Budget hold reuses `status: pending-approval` plus `wait_reason` (no extra label). Success lands in **`review`**, not `done`.

---

## Team hardening

| Step | Do this |
|------|---------|
| Bot identity | [docs/github-app.md](docs/github-app.md); comments as `svarm[bot]` |
| Approvals | **Required in production/Docker:** strong `APPROVALS_USER` / `APPROVALS_PASSWORD` before exposing the port. Gates `/approvals`, `/setup`, and board approve/reject/mark-done/answer/steer/overage. Missing credentials → board mutations fail closed (local Mix `dev_routes` may stay open). Keep `approval.mode: untrusted`. Board **reads** stay open — still firewall the UI (see [SECURITY.md](SECURITY.md)) |
| Agents | Edit `svarm-config/agents.toml` models; list required API keys in each agent’s `env` (no full host inheritance). Optional `skills` paths attach packs — start Svärm from a CWD where those packs live. Optional `tools` / `tools_mode` declare PATH executables (fail or warn before spawn; Svärm does not install them) ([docs/agents.md](docs/agents.md)) |
| Budgets | Optional: `SVARM_BUDGET_MAX_USD_PER_TICKET` / `SVARM_BUDGET_MAX_USD_PER_DAY` or WORKFLOW `budget.*` — block **new** spawns when spent ≥ cap. Mode `hard` (default) skips spawn; `hold` (`SVARM_BUDGET_MODE` / `budget.mode`) parks the ticket for a one-shot **Approve overage** on the board. Raising the cap also clears the hold. Estimated ledger rows count toward the cap. |
| CI resume | Optional: re-dispatch when a managed PR’s Checks fail (see below). **Off by default.** |
| Review resume | GitHub **changes requested** is detected on poll (board chip). Optional re-dispatch on first request (see below). **Off by default.** |
| Smoke-only off | Never leave `approval.mode: off` on a shared repo; do not leave `SVARM_DEMO_ROUTES` / `SVARM_SEED_DEMO` on production |
| Base URL | Point `SVARM_BASE_URL` at the deployed host (needed only if you opt in to comment console links) |
| Comment console links | **Off by default.** `SVARM_COMMENT_CONSOLE_LINKS=true` embeds `/board?task=…&attach=1` in GitHub run comments. Do not enable on a public repo while board reads are open ([SECURITY.md](SECURITY.md)) |
| HTTPS + host | Terminate TLS at a reverse proxy; set `PHX_HOST` to the public hostname (origin checks). Compose **app** leaves session cookies Secure by default; only set `PHX_SECURE_COOKIES=false` for plain-HTTP localhost. See [SECURITY.md](SECURITY.md) |
| Workspace isolation | Optional: `workspace.isolation` `path` (default) or `worktree`. Not a container. Unknown values fail closed (see below). |

### Workspace isolation

Per-ticket cwd lives under `workspace.root`. Isolation is a WORKFLOW switch, not an OS sandbox. Default stays **`path`**.

| Key | Values | Default |
|-----|--------|---------|
| `workspace.root` | Directory for per-ticket workspaces | template uses `~/svarm_workspaces` |
| `workspace.isolation` | `path` or `worktree` | **`path`** |
| `workspace.git_repo` | Source git repo path (needed for `worktree`) | unset |

Unknown `workspace.isolation` values (`container`, `sandbox`, typos) **fail closed**: `validate_workflow/1` returns `{:error, :invalid_workspace_isolation}` and the orchestrator will not dispatch until the key is `path`, `worktree`, or omitted.

| Isolation | What it is | What it is not |
|-----------|------------|----------------|
| `path` (default) | Per-ticket directory under `workspace.root` with a path-escape guard | OS sandbox, chroot, container |
| `worktree` | `git worktree` per ticket from `workspace.git_repo`; cleanup removes the tree; git add/list/remove are time-bounded (default 30s) | OS sandbox, container |
| `container` | Later | — |

### CI resume (optional)

When a Svärm-managed ticket lands in **review** with a PR, and **GitHub Checks** later fail, Svärm can **re-open the ticket** and spawn a **fresh** agent run with a short CI failure summary in the prompt (not a magic pi session resume). After **N** resume attempts, a **circuit** opens: no more auto-resume; the board shows **“CI retries exhausted”** while the card stays in `review` so you can still merge or intervene.

**Default is off** — enable only when you want automatic re-dispatch costs.

```yaml
# WORKFLOW.md front matter
ci_resume:
  enabled: true
  max_attempts: 3   # circuit after this many resume spawns
  skip_draft: true  # ignore draft PRs until ready
```

Env overrides:

| Variable | Effect |
|----------|--------|
| `SVARM_CI_RESUME_ENABLED` | `true` / `1` / `yes` enables |
| `SVARM_CI_RESUME_MAX_ATTEMPTS` | Positive integer (default 3) |

**Requirements:**

- GitHub tracker (Local has no Checks API)
- App/PAT permissions: **Checks: Read**, **Pull requests: Read** (write still needed for labels/PRs elsewhere) — see [docs/github-app.md](docs/github-app.md)
- PR URL captured from agent output (best-effort regex on the run log). Without a durable PR link, resume cannot poll.

**Costs:** each resume is a new spawn — usage ledger and budget caps still apply. In-flight runs are not killed when CI fails.

### Review resume (optional)

When a managed ticket is in **review** with a PR, Svärm **polls GitHub pull-request reviews** on the orchestrator tick (same poll loop as CI Checks — **no webhook**). If a reviewer’s **latest submitted** review is `CHANGES_REQUESTED`, the board card shows **“Changes requested”** and durable coordination records the signal + a short review context. Detection is on whenever the GitHub tracker is active.

When **enabled**, the **first** transition into changes-requested **re-opens the ticket** and spawns a **fresh** agent run with that review summary in the prompt. GitHub does not clear `CHANGES_REQUESTED` on a new push, so a later SHA refresh in the same episode is detection only. A new episode starts after reviews are no longer changes-requested (`:clear`) and then requested again.

Spawn shares the **CI resume circuit**: `ci_resume_count` / `ci_circuit_open` and `SVARM_CI_RESUME_MAX_ATTEMPTS` (or WORKFLOW `ci_resume.max_attempts`). After **N** combined resume attempts, the circuit opens; the board shows **“CI retries exhausted”** and the card stays in `review`.

**Default is off** — enable only when you want automatic re-dispatch costs. Local tracker has no Reviews API.

```yaml
# WORKFLOW.md front matter
review_resume:
  enabled: true
```

Env overrides:

| Variable | Effect |
|----------|--------|
| `SVARM_REVIEW_RESUME_ENABLED` | `true` / `1` / `yes` enables spawn (env wins over WORKFLOW) |

**Requirements:** GitHub tracker; App/PAT **Pull requests: Read & write** (read for reviews; write to move the issue back to `todo`, same as CI resume) — see [docs/github-app.md](docs/github-app.md). Polls are capped per tick like CI resume.

**Costs:** each resume is a new spawn — usage ledger and budget caps still apply. In-flight runs are not killed when a review asks for changes.

---

## Agent asked a question

A **PiRPC** agent can pause mid-run on a dialog (`confirm`, `select`, `input`, or `editor`). The board card shows **Waiting for answer** even while the run is still `in_progress`. Open the card, answer the prompt, or **Dismiss**.

- One pending question at a time — this is not a chat thread.
- Dismiss or the wait deadline **continues** the run (it does not fail solely because you were slow).
- Default deadline is **15 minutes** (`SVARM_AGENT_QUESTION_TIMEOUT_MS`, or a shorter timeout on the pi request).
- **CLI** agents cannot be answered this way (unsupported). Fire-and-forget UI (`notify`, status widgets) never waits.

Answering uses the same board auth as approve/reject (`APPROVALS_*` + `board_auth_at` TTL).

---

## Steer a live run

While a **PiRPC** run is `in_progress` (and not waiting on a question), the console has a **Steer** field. That queues a pi `steer` message: after the current tool calls finish, the agent sees your note before the next model call.

- Same board auth as approve / answer.
- **CLI** runs show the control disabled — steer is Pi RPC only.
- Spend stays on the same run (`message_end` usage). This is not a new ticket.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Container exits immediately | Check `docker compose logs`. `SECRET_KEY_BASE` is generated if unset; set it in `.env` only for stable sessions |
| Config is a directory named `WORKFLOW.md` | Old file mounts. Use directory mount `./svarm-config:/app/config` (current compose) and delete the bogus dirs |
| `/approvals` 404 text about APPROVALS_* | Set `APPROVALS_USER` and `APPROVALS_PASSWORD` in `.env` |
| Board approve/reject/mark-done/answer/steer/overage blocked without auth flash | Production needs `APPROVALS_*`; sign in via `/approvals` then return to the board. Local Mix without credentials is open only when `dev_routes` is on. Sticky proof expires after 8h by default (`BOARD_AUTH_TTL_SECONDS`) — re-sign in if mid-session mutations start failing |
| `/approvals` 401 | Wrong Basic Auth credentials |
| Nothing happens | `docker compose logs -f` (polling / eligibility) |
| Tick never dispatches after a WORKFLOW edit | Invalid `workspace.isolation` fails closed (expected `path` or `worktree`); logs include the rejected value |
| Stuck before agent runs | `/approvals` (default is untrusted) |
| 401/403 from GitHub | PAT `repo` scope; token in `.env` |
| No eligible issues | Issue has `ai-task`; `required_labels` matches |
| pi not found (local) | `which pi`; Docker image includes pi |
| OpenRouter errors | `OPENROUTER_API_KEY` set |
| Empty board | Demo (`--profile demo`) or Seed demo; the real tracker loop needs a labeled issue |
| `mix svarm.demo` ≠ `/board` | Expected: Mix task uses a temp DB. Use Seed demo on the running server |
| Sessions / approvals sticky auth fail on local HTTP `app` | Set `PHX_SECURE_COOKIES=false` in `.env` (Secure cookies need HTTPS; demo profile sets this already) |

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
| Zero-key aha again | Demo profile / Seed demo |
| Use Claude Code | [docs/agents.md](docs/agents.md) copy-paste blocks, or edit **agents.toml** |
| Attach the sample skill pack | Enable `priv/packs/ai-task` on an agent — [docs/agents.md](docs/agents.md#sample-pack-ai-task) |
| Bot identity on comments | [docs/github-app.md](docs/github-app.md) |
| Other trackers (Linear/Jira) | Not in OSS yet. GitHub + local only today |
| Export costs to CSV/JSON | `mix svarm.export_usage --format csv` (or `json`; optional `--out path`). Costs also on the board and in GitHub comments |
| Spend by outcome (API) | `Svarm.Usage.by_outcome(task_statuses: …)` — buckets `:merged` (status `done`, or GitHub PR `merged` when coordination recorded a PR), `:in_review`, `:other`. Query-time only (ledger stays append-only). Local / no-PR is status-based. Closed-unmerged and GitHub API errors do not invent merges. Estimated spend flagged. See `Svarm.Usage.Outcomes` |
| Per-agent 24h cost / retry | [`/dashboard`](http://localhost:4000/dashboard) roster — wall-clock last 24 hours; estimated spend labeled; retry is n/a when attempts are not recorded (GitHub today) |
