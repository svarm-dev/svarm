# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in Svärm, report it responsibly:

1. **GitHub Security Advisory** (preferred): Use [GitHub's private vulnerability reporting](https://github.com/svarm-dev/svarm/security/advisories/new)
2. **Email**: Send details to the repository owner via the email in the Git commit history

Do **not** open a public GitHub Issue for security vulnerabilities.

## Response timeline

- **Acknowledge** within 48 hours
- **Fix** critical issues within 7 days
- **Fix** high/medium issues within 30 days
- You'll be credited in the fix (unless you prefer anonymity)

## Scope

**In scope:**
- Authentication bypass (approvals, dev routes)
- Secret injection or exfiltration via agent commands
- Workspace path escape (breaking out of the configured workspace root)
- Remote code execution via crafted WORKFLOW.md or agents.toml
- SQL injection through Ecto/Elixir layer
- Cross-site scripting (XSS) in the LiveView dashboard

**Out of scope:**
- Social engineering
- Dependency vulnerabilities (report upstream to the dependency)
- Denial of service (Svärm is self-hosted single-node by design)
- Issues in third-party agents (pi, Claude Code) or LLM providers (OpenRouter)

## Security model

Svärm is self-hosted. The operator controls:

- **API keys**: stored in `.env` or environment variables, never in config files or logs
- **Agent commands**: agents run arbitrary commands in isolated workspace directories
- **Approval gates**: `approval.mode: untrusted` holds tasks until a human approves (see sticky-approval note below)
- **Workspace path isolation**: `Workspace.ensure/2` keeps per-ticket directories under a configured root (cwd + path-escape guard — not a chroot or container)
- **Secrets in transit**: never appear in task metadata, PubSub messages, or issue comments

The first-run approval gate (`approval.mode: untrusted`) prevents unattended execution until the operator explicitly approves. **One-shot sticky approval:** after a human approves, the orchestrator records the task id and the next poll may dispatch without re-entering `pending_approval`. The one-shot bit is cleared after the first spawn attempt — if the agent fails back to `todo`, a later poll can re-gate. Use `trusted_assignees` for agents that should skip the gate entirely. Under `mode: untrusted`, only assignees listed in `approval.trusted_assignees` skip the gate. The default template trusts `default`, `demo_research`, and `demo_docs`; **`demo_code` is gated** so the approval UX is visible during zero-key onboarding. Demo seed also applies a runtime overlay (trusts only `demo_research` and `demo_docs`) while a demo profile flag is active (`SVARM_SEED_DEMO` / `SVARM_DEMO_ROUTES` / dev routes). The overlay never weakens a WORKFLOW `mode: all` policy (everyone stays gated).

### Sticky demo approval overlay

While any of `seed_demo_on_boot`, `demo_routes`, or `dev_routes` is active, a prior Seed’s process-global `:approval_overlay` stays merged into Orchestrator approval state until process exit or a non-demo boot that clears it. Operators editing WORKFLOW trust lists in a long-lived `mix phx.server` (which typically runs with `dev_routes`) should expect the overlay to win for trusted assignees until restart or an env without those flags. Demo profile includes `dev_routes` by design; there is no mid-session UI to clear the overlay today.

### Approvals surfaces

| Surface | Auth model |
|---------|------------|
| `/approvals` | Basic Auth when `APPROVALS_USER` / `APPROVALS_PASSWORD` are set |
| `/setup` | Same Basic Auth (or `dev_routes` in local Mix) |
| `/board` LiveView **reads** | Open when the process is reachable (still firewall for real repos) |
| `/board` approve / reject / mark done | Same `APPROVALS_*` credentials when configured; mutations fail closed without proof. When credentials are **unset**: open only with local Mix `dev_routes`; **production / Docker fail closed** (no approve/reject/mark-done until credentials are set) |

A successful Basic Auth request (e.g. `/approvals`) sets a sticky session flag for board mutations; follow-up requests without the Authorization header keep mutation rights until the session ends. Browsers that re-send Basic Auth after a challenge also work.

Local Mix (`dev_routes: true`) keeps board mutations open without Basic Auth so day-to-day development stays usable. **Production and Docker do not set `dev_routes`:** forgetting `APPROVALS_USER` / `APPROVALS_PASSWORD` must not leave approve/reject/mark-done open on an exposed port. Prefer app-level `APPROVALS_*`; a reverse proxy that authenticates all traffic is an additional layer, not a substitute for configuring credentials when you want the built-in gates.

### Agent child environment

Agent Port processes receive a **small allowlist** of host env vars (PATH, HOME, locale, temp, shell) plus keys listed in the agent’s `env` map in `agents.toml`. Empty `env` does **not** inherit the full host environment — API keys such as `OPENROUTER_API_KEY` must be listed explicitly (e.g. `OPENROUTER_API_KEY = "$OPENROUTER_API_KEY"`). GitHub App mode still injects installation tokens as `GITHUB_TOKEN` / `GH_TOKEN` when the tracker uses App auth.

### Hard spend caps

Optional hard caps at preflight: `SVARM_BUDGET_MAX_USD_PER_TICKET` / `SVARM_BUDGET_MAX_USD_PER_DAY` (env) and WORKFLOW `budget.max_usd_per_ticket` / `budget.max_usd_per_day`. When both sources set a field, the **stricter** (lower) value wins. Caps block **new** spawns; in-flight runs are not killed. Estimated ledger rows count toward the cap. Unset = no hard stop.

## Production hardening

For team/production deployments:

- **Required before exposing the port:** set strong `APPROVALS_USER` and `APPROVALS_PASSWORD` in `.env`. Without them, production **fails closed** on board approve/reject/mark-done (and `/approvals` / `/setup` stay disabled). Set credentials before you open the UI to a network.
- Bind or firewall the UI so only trusted operators reach the process (board **reads** are not Basic-Auth gated even when credentials are set)
- Use a real `SECRET_KEY_BASE` (not the auto-generated one)
- Keep `approval.mode: untrusted` (the default)
- Review agent commands and `env` keys in `agents.toml` before enabling (no silent full-env inheritance)
- Optionally set hard budget caps for design-partner / Show HN deploys
- Do **not** expose the demo profile on shared hosts (`SVARM_DEMO_ROUTES` / `SVARM_SEED_DEMO`)
- Rotate API keys if a team member with access leaves
- Put the UI behind **HTTPS** (TLS at a reverse proxy is fine). Raw HTTP on a public port is unsupported.

### Reverse proxy, host, and cookies

Production runtime enables LiveView/WebSocket **origin checks** from `PHX_HOST` (not open). Session cookies default to **`Secure`** so browsers only send them over HTTPS.

| Variable | Role |
|----------|------|
| `PHX_HOST` | Public hostname used for URL generation and default origin allow-list (`//PHX_HOST`) |
| `PHX_CHECK_ORIGIN` | Optional comma-separated allow-list when you need extra hosts/origins |
| `PHX_SECURE_COOKIES` | Session `Secure` flag (prod default `true`). **Today** both compose `app` and `demo` inject `PHX_SECURE_COOKIES=false` by default — fine for plain-HTTP localhost; **set `PHX_SECURE_COOKIES=true` (or remove the override) for any HTTPS / reverse-proxy deploy** until compose is fixed ([#97](https://github.com/svarm-dev/svarm/issues/97)) |

**Proxy assumptions:** terminate TLS at Caddy/nginx/NPM/etc., forward to the container on port 4000, and pass `Host` (and `X-Forwarded-Proto` if you later enable app-level `force_ssl`). Set `PHX_HOST` / `SVARM_BASE_URL` to the public name operators open in the browser. App-level `force_ssl` may remain proxy-owned — see `config/prod.exs`.
