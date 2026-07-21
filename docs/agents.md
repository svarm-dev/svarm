# Agent definitions (operators)

Copy a block into **`svarm-config/agents.toml`** (Docker) or **`priv/agents.toml`** (local defaults).  
Secrets stay in `.env` — never in these files.

See also path **B** in [GETTING-STARTED.md](../GETTING-STARTED.md).

## Default (pi + OpenRouter)

```toml
[agent.default]
name = "Pi"
role = "Backend"
command = "pi"
adapter = "pi_rpc"
provider = "openrouter"
model = "openrouter/free"
env = { GITHUB_TOKEN = "$GITHUB_TOKEN" }
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
| `env` | Extra env; `$VAR` expands from the process environment |

Coding agents **editing this repository** (not swarm members): see root [AGENTS.md](../AGENTS.md).
