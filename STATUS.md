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
| **Updated** | 2026-08-10 |
| **`main`** | `34e518e` — perf(board): reduce LiveView load (#104) |
| **Latest tag** | **v0.1.3** (2026-08-02) |
| **Unreleased** | Run console, CI resume (default off), trust/perf — see CHANGELOG |
| **Focus** | **[#48](https://github.com/svarm-dev/svarm/issues/48)** — thin toolchain preflight + shared agent skills |
| **Next** | [#49](https://github.com/svarm-dev/svarm/issues/49) typed stream · [#50](https://github.com/svarm-dev/svarm/issues/50) review-changes resume |

`main` STATUS **lags open PR branches** — always check `gh pr list` / `gh issue list` for live work.

---

## Blocked (human / external)

_None known._  
Format: `YYYY-MM-DD · one sentence · issue/PR link`

---

## Session log (newest first, max 3)

- 2026-08-10 · slim STATUS after independent review (#105)
- 2026-08-10 · main · #104 board streams · #103 tests · #102 auth TTL
