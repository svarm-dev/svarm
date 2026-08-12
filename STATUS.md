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
| **Updated** | 2026-08-12 |
| **`main`** | `149ab76` — feat(skills): agents.toml skills path schema + docs (#117) |
| **Latest tag** | **v0.1.3** (2026-08-02) |
| **Unreleased** | Run console, CI resume (default off), skills inject, sample pack, trust/perf — see CHANGELOG |
| **Focus** | **[#108](https://github.com/svarm-dev/svarm/issues/108)** — toolchain preflight contract fail/warn |
| **Next** | Typed stream / review-resume children under later epics |

`main` STATUS **lags open PR branches** — always check `gh pr list` / `gh issue list` for live work.

---

## Blocked (human / external)

_None known._  
Format: `YYYY-MM-DD · one sentence · issue/PR link`

---

## Session log (newest first, max 3)

- 2026-08-12 · sample ai-task pack (#52)
- 2026-08-11 · skills dispatch inject (#107); Focus → #108
- 2026-08-10 · slim STATUS after independent review (#105)
