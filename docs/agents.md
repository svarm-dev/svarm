# Agent definitions (operators)

Copy a block into **`svarm-config/agents.toml`** (Docker) or **`priv/agents.toml`** (local defaults).  
Secrets stay in `.env` — never in these files.

See also the real tracker loop in [GETTING-STARTED.md](../GETTING-STARTED.md).

## Default (pi + OpenRouter)

```toml
[agent.default]
name = "Pi"
role = "Backend"
command = "pi"
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"
env = { GITHUB_TOKEN = "$GITHUB_TOKEN", OPENROUTER_API_KEY = "$OPENROUTER_API_KEY" }
```

## Claude Code (CLI)

```toml
[agent.claude]
name = "Claude"
role = "Implementation"
command = "claude"
args = ["-p", "--output-format", "text"]
adapter = "cli"
provider = "openrouter"
model = "anthropic/claude-sonnet-4"
```

## Codex (CLI)

```toml
[agent.codex]
name = "Codex"
command = "codex"
args = ["exec", "--skip-git-repo-check"]
adapter = "cli"
```

## Aider (CLI)

```toml
[agent.aider]
name = "Aider"
command = "aider"
args = ["--message", "--yes-always"]
adapter = "cli"
```

## Demo agents (zero-key)

Already in the default `agents.toml` as `demo_research` / `demo_code` / `demo_docs`.  
Trusted under default `approval.mode: untrusted`. Used by Seed demo / `SVARM_SEED_DEMO=1`.

## Fields

| Field | Notes |
|-------|--------|
| `command` | Executable on PATH (or container PATH) |
| `adapter` | `pi_rpc` or `cli` |
| `provider` / `model` | LLM routing for adapters that use them |
| `args` | CLI only |
| `env` | Extra env for the child Port; `$VAR` expands from the **host** process. Empty/absent `env` does **not** inherit the full host environment — only PATH/HOME/locale/temp/shell plus listed keys. Put API keys here explicitly (e.g. `OPENROUTER_API_KEY = "$OPENROUTER_API_KEY"`). |
| `skills` | Optional list of **paths** to skill packs (see below). Omitted or empty means no packs. |
| `tools` | Optional list of **host executable names** expected on PATH (e.g. `mix`, `node`, `gh`). Omitted or empty means no extra tools required. **Not an installer** — Svärm only checks PATH. |
| `tools_mode` | `fail` (default) or `warn`. What to do when a declared tool is missing (see below). |

## Host tools (`tools` / `tools_mode`)

Declare a **PATH-only contract** for tools the agent (or its scripts) expects on the host. Svärm does **not** install runtimes, language toolchains, or packages.

```toml
[agent.default]
name = "Pi"
command = "pi"
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"
# Cheap preflight before spawn — no model spend
tools = ["mix", "gh", "node"]
tools_mode = "fail"   # default if omitted; use "warn" to start anyway
```

| Rule | Detail |
|------|--------|
| Layout | TOML array of strings under `tools`; optional `tools_mode` string |
| Check | Before spawn (alongside budget), each name is looked up with `System.find_executable/1` |
| Cost | PATH lookup only — no LLM or API calls |
| Omitted / empty | No extra tools required; preflight is a no-op |
| Malformed entries | Non-string or blank values are dropped at load; load still succeeds |
| `tools_mode = "fail"` (default) | Missing tools → task marked **failed**, clear board line (`[toolchain: …]`), agent process **not** started |
| `tools_mode = "warn"` | Missing tools → board/log note that the agent expects them, then spawn continues |
| Settings overlay | `/setup` / Settings can replace `tools` (list replace) and set `tools_mode` for a known agent name |

**Install tools on the host (or container image) yourself**, then declare them so a missing `mix` fails closed instead of burning tokens mid-run.

## Skill packs (`skills`)

Attach the same playbook to every run of a named agent by listing **filesystem paths** — not marketplace pack IDs (there is no registry).

```toml
[agent.default]
name = "Pi"
role = "Backend"
command = "pi"
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"
env = { GITHUB_TOKEN = "$GITHUB_TOKEN", OPENROUTER_API_KEY = "$OPENROUTER_API_KEY" }
# Pack directories and/or SKILL.md files (paths only)
skills = [
  "packs/backend",
  "/opt/svarm-packs/elixir"
]
```

| Rule | Detail |
|------|--------|
| Layout | TOML array of strings under `skills` on the agent table |
| Paths | Absolute, or **relative to the process working directory** when Svärm starts |
| Pack shape | Each path is a **directory with `SKILL.md`**, or a **`.md` file** (copied as `SKILL.md`) |
| Omitted / empty | Loader sets `skills` to `[]` — no packs injected |
| Malformed entries | Non-string or blank values are dropped at load; load still succeeds |
| Settings overlay | `/setup` / Settings can replace `skills` for a known agent name (list replace, not append) |
| Dispatch inject | At run start, packs are **copied** into the ticket workspace under `.agents/skills/<name>/` |
| Fail closed | Missing path, directory without `SKILL.md`, or name conflict → task `failed` with a clear board line (no silent skip) |
| Prompt note | A short “Attached skill packs” section is appended so CLI agents see the paths |
| Pi RPC | Also passes `--skill <dest>` per pack so skills load even on an untrusted fresh workspace |

**Run Svärm where toolchains and packs live.** Relative pack paths resolve from the host CWD (or container workdir), not from the ticket workspace. Keep packs on the operator host; Svärm does not install or vendor them.

Each pack follows the [Agent Skills](https://agentskills.io/specification) layout (`SKILL.md` + optional scripts/references). Pi discovers project skills under `.agents/skills/`; the workspace copy is the shared contract for CLI runners too.

## Sample pack: ai-task

The repo ships one reference pack, [`priv/packs/ai-task/`](../priv/packs/ai-task/SKILL.md): repo-citizenship conventions for working a board ticket (read the repo's AGENTS.md, keep scope to the ticket, run the project's own verify gate, `Closes #N`, never merge). The body is plain markdown and harness-agnostic — pi RPC receives it via `--skill`, CLI agents via the workspace copy plus the prompt note above.

Enable it on an agent:

| Install | `skills` entry |
|---------|----------------|
| Local, started from the repo root | `["priv/packs/ai-task"]` |
| Docker image | `["/app/packs/ai-task"]` |
| Any other layout | `cp -r priv/packs/ai-task "$HOME/.svarm/packs/"` once, then the absolute path, e.g. `["/home/you/.svarm/packs/ai-task"]` |

Paths go through `Path.expand/1` — `~` is **not** expanded, so use the absolute path.

Run a ticket: label an issue `ai-task`, approve the run, watch the board. The ticket workspace gets `.agents/skills/ai-task/SKILL.md` and the prompt lists the pack. Zero-key check: attach the pack to `agent.demo` and **Seed demo** — inject runs for demo agents too (and a wrong path fails the demo run closed, which is the cheapest way to see the failure line).

Your own packs need no fork: put a directory with a `SKILL.md` anywhere on the host and list its path. Settings (`/setup`) replaces the list per known agent name.

## Pi RPC profile (default for the real tracker loop)

Default adapter `pi_rpc` spawns **`pi --mode rpc --no-session`** (+ provider/model/name).

| Knob | Default | Where |
|------|---------|--------|
| Run timeout (wall-clock) | **45 min** | `Svarm.Runner.PiRPC` (`@default_timeout_ms`); not idle-reset |
| Orchestrator stall | **45 min** | WORKFLOW `agent.stall_timeout_ms` |
| Completion | `agent_settled` only | non-zero exit / no settle → `failed` |
| Mid-run UI (`extension_ui_request`) | **park + inject** (dialogs) | `AgentQuestion`; fire-and-forget ignored; invalid dialog fails the run; CLI unsupported |
| Operator steer | **live `type: steer`** | `RunSteer` → PiRPC JSONL; CLI unsupported; hidden while a question is parked |

**Keep PiRPC timeout ≤ stall.** The runner uses a **wall-clock** deadline (streaming does not reset it), then aborts (JSONL `abort` → grace → `kill_tree`). Orchestrator stall only `Process.exit`s the worker Task (Port close is best-effort, no kill_tree). Raise both together for longer coding sessions.

Missing `pi` on PATH → task `failed` with `[pi_rpc: pi not found on PATH]`. Broken protocol / rejected prompt → `failed` with a protocol board line.

Flags: `--mode rpc --no-session`. Session resume is not in v0.1.x. Mid-run dialogs park until a board answer, cancel, or the wait deadline (default 15 min). Operator **steer** from the board is a live pi `steer` on that same session.

Coding agents **editing this repository** (not swarm members): see root [AGENTS.md](../AGENTS.md).
