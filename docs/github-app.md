# GitHub App identity

Use a **GitHub App** so Svärm comments, claims, and optional agent git ops appear as `{app-slug}[bot]` instead of a personal PAT.

GitHub App **names are global**. `Svärm` / `svarm` may already be taken — that is fine. The product is still Svärm; the App is just the bot identity. Pick any free name; comments appear as `{slug}[bot]` (e.g. `svarm-bot[bot]`).

Suggested names if `svarm` is taken: `svarm-bot`, `svarm-orchestrator`, `svarm-hq`, `yourorg-svarm`.

## Goal

| Surface | PAT (`auth: token`) | App (`auth: app`) |
|---------|---------------------|-------------------|
| Issue comments, labels, claim | Human who owns `GITHUB_TOKEN` | `{app-slug}[bot]` (installation) |
| Agent clone/push/PR | Same PAT via env | Same installation token injected as `GITHUB_TOKEN` / `GH_TOKEN` |
| Agent personality | Comment body (`agent_name`, harness, model, session) | Unchanged |

## Auth flow

1. Build App JWT (RS256, `iss` = App ID, `iat`/`exp` ≤ 10 min) from private key PEM.
2. Resolve `installation_id` from config, or `GET /repos/{owner}/{repo}/installation`.
3. `POST /app/installations/{id}/access_tokens` → installation token (~1h).
4. Use `Authorization: Bearer <token>` for all GitHub REST calls (API version `2026-03-10`).
5. Cache token until ~60s before expiry. Treat token string as opaque (format may be `ghs_…`).

## Config

```yaml
tracker:
  kind: github
  owner: my-org
  repo: my-project
  auth: app                    # app | token (default: token for back-compat)
  app_id: $SVARM_GITHUB_APP_ID
  # installation_id: $SVARM_GITHUB_INSTALLATION_ID  # optional; resolved via API if omitted
  private_key_path: $SVARM_GITHUB_APP_KEY_PATH      # path to PEM file
  # legacy:
  # api_key: $GITHUB_TOKEN
```

Env:

| Variable | Required when `auth: app` |
|----------|---------------------------|
| `SVARM_GITHUB_APP_ID` | Yes |
| `SVARM_GITHUB_APP_KEY_PATH` | Yes (PEM path), **or** `SVARM_GITHUB_APP_PRIVATE_KEY` (PEM contents) |
| `SVARM_GITHUB_INSTALLATION_ID` | Optional |

Never put PEM contents in WORKFLOW.md, git, logs, or PubSub.

## Minimal App permissions

| Permission | Access | Why |
|------------|--------|-----|
| Issues | Read & write | List, labels, comments |
| Metadata | Read | Required |
| Contents | Read & write | Clone/push when agent uses App token |
| Pull requests | Read & write | Open PR |
| **Checks** | **Read** | CI resume: poll check-runs on managed PRs (optional feature) |

Webhook: disabled for v1 (poll loop). CI resume also uses poll-on-tick, not webhooks.

## Operator setup checklist

1. GitHub → Settings → Developer settings → **New GitHub App**
2. **Name:** any free slug (not the product trademark). Try `svarm-bot` / `svarm-orchestrator` if `svarm` is taken. Webhook **inactive**.
3. Permissions: Issues RW, Contents RW, PRs RW, Metadata R; Checks R if using CI resume
4. Generate private key → store PEM outside the repo
5. Install App on the target repo(s)
6. Set env vars; WORKFLOW `auth: app`
7. Verify: issue comment author is `* [bot]`, not your user

## Non-goals (v1 self-host)

- Per-agent GitHub Apps
- Webhooks
- OS keychain
- Marketplace listing

Self-host: **you are the App** (you create App + hold PEM + install). A future managed tier may flip that so one public App is installed with a click.

## Security

- Secrets only in env / PEM file path
- Never log JWT or installation tokens
- PAT (`auth: token`) remains supported for local demos
