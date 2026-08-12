# GitHub labels

Short guide to labels used on [svarm-dev/svarm](https://github.com/svarm-dev/svarm) issues and PRs. Labels describe **kind** and **delivery state** — they are not a private roadmap rank.

## Kind

| Label | Meaning |
|-------|---------|
| `enhancement` | New capability or improvement |
| `bug` | Something broken vs expected behaviour |
| `documentation` | Docs-only change |
| `dependencies` | Dependency updates (e.g. Dependabot) |
| `governance` | Approvals, trust floor, control-plane policy |
| `cost` | Usage ledger, budgets, receipts |
| `security` | Auth, secrets, isolation |
| `good first issue` | Good for newcomers |
| `help wanted` | Extra attention is needed |
| `question` | Further information is requested |
| `duplicate` | Same as another issue |
| `invalid` | Not actionable as filed |
| `wontfix` | Deliberate non-goal — not a backlog item |

## Claimability

| Label | Meaning |
|-------|---------|
| `ai-task` | Safe for Svärm or an external coding agent to claim. Use only when acceptance criteria are concrete and agent-safe (see [CONTRIBUTING.md](../CONTRIBUTING.md)). |

Epics are **not** labeled `ai-task`. Claim children, not parents.

## Delivery (optional)

| Label | Meaning |
|-------|---------|
| `status: in-progress` | Actively being worked |
| `status: review` | PR open / human review |

These are delivery signals, not roadmap priority.

## Issue shapes

See [CONTRIBUTING.md](../CONTRIBUTING.md) for **Bug report**, **Feature request**, **Ready to build**, and **Epic** templates. Epic children use titles like `scope: short name` (e.g. `toolchain: preflight contract fail/warn`) and start the body with `Part of #N`.
