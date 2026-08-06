# Contributing to Svärm

Thanks for your interest in contributing. This document covers how to report bugs, suggest features, and submit pull requests.

## Reporting bugs

Open a [GitHub Issue](https://github.com/svarm-dev/svarm/issues/new) with:

- What you expected to happen
- What actually happened
- Steps to reproduce (as specific as possible)
- Environment: OS, Elixir version, OTP version, Docker or Mix

If the bug involves agent dispatch or cost tracking, include the output of `mix svarm.demo` or the relevant `/board` state.

## Suggesting features

Open a [GitHub Issue](https://github.com/svarm-dev/svarm/issues/new) (label `enhancement` if you can). Describe:

- The problem you're trying to solve
- Your proposed solution (if you have one)
- Why it matters for the project's goals (see README for what Svärm is)

## Submitting pull requests

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Run quality checks before submitting:

```bash
mix precommit    # compile, unused deps, format, full test suite
```

For larger changes:

```bash
mix ci           # compile, format check, test, credo, dialyzer, deps.audit, sobelow, ex_dna, reach
```

GitHub Actions runs the same `mix ci` on pushes to `main` and on pull requests.

4. Submit the PR with a clear description of what changed and why

### Code style

- Elixir formatter (`mix format`) — non-negotiable
- Pattern match in function heads, not `if` inside a single clause
- Tagged tuples for results: `{:ok, value}` / `{:error, reason}`
- No dynamic atom creation from external input
- `Req` for all HTTP (no `httpoison`, `tesla`, `httpc`)

### Tests

- Add tests for new behaviour, not implementation details
- Database-touching tests use `async: false` (SQLite serializes writes)
- Run `mix test` before submitting
- For agent runner changes, test with `mix svarm.demo` first

### Architecture

Read [AGENTS.md](AGENTS.md) for the module boundaries and supervision tree. Key rules:

- Only `AgentRunner` shells out (`System.cmd`, `Port.open`)
- Only `KanbanBridge` touches the database
- Web layer is read-only (never calls `AgentRunner` or `Workspace` directly)

## Coding agents

If you're a coding agent (pi, Claude Code, etc.) editing this repo, see [AGENTS.md](AGENTS.md) for the full contract.

## License

By contributing, you agree that your contributions are licensed under the same terms as the project: [FSL-1.1-MIT](LICENSE) (Functional Source License → MIT after two years per version). See [README](README.md#license) for a plain-language summary.
