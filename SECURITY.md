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

The first-run approval gate (`approval.mode: untrusted`) prevents unattended execution until the operator explicitly approves. Demo assignees (`demo_*`) skip the gate for zero-key onboarding.

## Production hardening

For team/production deployments:

- Set `APPROVALS_USER` and `APPROVALS_PASSWORD` in `.env`
- Use a real `SECRET_KEY_BASE` (not the auto-generated one)
- Keep `approval.mode: untrusted` (the default)
- Review agent commands in `agents.toml` before enabling
- Rotate API keys if a team member with access leaves
