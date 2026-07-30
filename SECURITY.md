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
- Workspace path escape (breaking out of the sandbox)
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
- **Approval gates**: `approval.mode: untrusted` requires human approval before first dispatch
- **Workspace sandbox**: `Workspace.ensure/2` validates paths stay within the configured root
- **Secrets in transit**: never appear in task metadata, PubSub messages, or issue comments

The first-run approval gate (`approval.mode: untrusted`) prevents unattended execution until the operator explicitly approves. Under `mode: untrusted`, only assignees listed in `approval.trusted_assignees` skip the gate. The default template trusts `default`, `demo_research`, and `demo_docs`; **`demo_code` is gated** so the approval UX is visible during zero-key onboarding. Demo seed also applies a runtime overlay (trusts only `demo_research` and `demo_docs`) while a demo profile flag is active (`SVARM_SEED_DEMO` / `SVARM_DEMO_ROUTES` / dev routes). The overlay never weakens a WORKFLOW `mode: all` policy (everyone stays gated).

### Sticky demo approval overlay

While any of `seed_demo_on_boot`, `demo_routes`, or `dev_routes` is active, a prior Seed’s process-global `:approval_overlay` stays merged into Orchestrator approval state until process exit or a non-demo boot that clears it. Operators editing WORKFLOW trust lists in a long-lived `mix phx.server` (which typically runs with `dev_routes`) should expect the overlay to win for trusted assignees until restart or an env without those flags. Demo profile includes `dev_routes` by design; there is no mid-session UI to clear the overlay today.

### Approvals surfaces

| Surface | Auth model |
|---------|------------|
| `/approvals` | Basic Auth when `APPROVALS_USER` / `APPROVALS_PASSWORD` are set |
| `/board` LiveView approve / reject | **Not** behind ApprovalsAuth — anyone who can reach the app can approve or reject pending tasks |

That is intentional for self-hosted network trust: bind or firewall the UI; do not expose the board on a shared host without network controls. Board Basic Auth is not implemented today.

## Production hardening

For team/production deployments:

- Bind or firewall the UI so only trusted operators reach `/board` (board approve/reject has no Basic Auth)
- Set strong `APPROVALS_USER` and `APPROVALS_PASSWORD` in `.env` (gates `/approvals` and `/setup` in Docker)
- Use a real `SECRET_KEY_BASE` (not the auto-generated one)
- Keep `approval.mode: untrusted` (the default)
- Review agent commands in `agents.toml` before enabling
- Do **not** expose the demo profile on shared hosts (`SVARM_DEMO_ROUTES` / `SVARM_SEED_DEMO`)
- Rotate API keys if a team member with access leaves
