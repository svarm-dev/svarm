# STATUS — coding-agent progress

> Short snapshot for coding agents and maintainers.  
> **Not** the product roadmap — open GitHub issues win if anything conflicts.  
> **Not** a diary. Prefer silence over noise.

## Noise rules

1. Update this file **only inside a real work PR** (same PR as code/docs that already needed to land).
2. **Never** a STATUS-only commit or PR (bootstrap #105 was the exception).
3. Change only fields that actually moved + at most **one** session-log line (max **3** lines total in the log).
4. No secrets. No private paths. No strategy essays.

If nothing material changed, **do not** edit this file.

### Focus ownership

- **Focus** = the single issue coding agents should claim next.
- Set or advance Focus only when: (a) a maintainer opens/reprioritizes the claim issue, or (b) the coding agent’s work PR closes that focus issue and points Focus at the next agreed issue **in that same PR**.
- Never a Focus-only commit.

---

## Snapshot

| Field | Value |
|-------|--------|
| **Updated** | 2026-08-16 |
| **`main`** | v0.1.5 + soft budget hold (#45) |
| **Latest tag** | **v0.1.5** (2026-08-14) |
| **Unreleased** | soft budget hold (#45); dashboard agent 24h cost + retry share (#54) |
| **Focus** | _(none — do not auto-claim #53 / #118)_ |
| **Next** | do not auto-claim #53 / #118 |

`main` STATUS **lags open PR branches** — always check `gh pr list` / `gh issue list` for live work.

---

## Blocked (human / external)

_None known._  
Format: `YYYY-MM-DD · one sentence · issue/PR link`

---

## Session log (newest first, max 3)

- 2026-08-16 · dashboard roster 24h cost + retry n/a (#54)
- 2026-08-16 · soft budget hold (#45); Focus → #54
- 2026-08-14 · cut v0.1.5 (#142); README Status honest about mid-run Q&A
