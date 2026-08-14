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
| **Updated** | 2026-08-14 |
| **`main`** | (this PR) compact terminal run console (#130) |
| **Latest tag** | **v0.1.4** (2026-08-14) |
| **Unreleased** | Compact terminal run console — see CHANGELOG |
| **Focus** | **[#113](https://github.com/svarm-dev/svarm/issues/113)** — review-resume: re-dispatch + shared circuit |
| **Next** | mid-run Q&A children (#114–#116) |

`main` STATUS **lags open PR branches** — always check `gh pr list` / `gh issue list` for live work.

---

## Blocked (human / external)

_None known._  
Format: `YYYY-MM-DD · one sentence · issue/PR link`

---

## Session log (newest first, max 3)

- 2026-08-14 · compact terminal run console (#130); Focus unchanged
- 2026-08-14 · v0.1.4 cut + README screenshots (#135, #136); Focus stays #113
- 2026-08-13 · review-resume GitHub changes-requested signal (#112); Focus → #113
