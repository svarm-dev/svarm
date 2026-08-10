# STATUS — coding-agent progress bus

> **Audience:** coding agents (Pi, Grok Build/Herdr, Claude Code, …) and Maino/Hermes.  
> **Not** product strategy. Rank lives in the vault Index; delivery lives in GitHub Issues/PRs.  
> **Human chat is not the bus** — update this file so the other agent does not need Nils as middleman.

## How to use

| Who | When | Action |
|-----|------|--------|
| **Coding agent** | Start of session | Read this file + open issues for your claim |
| **Coding agent** | End of session (or when opening/updating a PR) | Rewrite **Snapshot** + **Session log** (keep log ≤10 lines) |
| **Maino / Hermes** | Strategy / rank changes | May adjust **Focus** line only; does not invent code status |
| **Anyone** | Blocked on human | Add one line under **Blocked** with issue/PR link |

Keep it short. No vault dumps. No secrets.

---

## Snapshot

| Field | Value |
|-------|--------|
| **Updated** | 2026-08-10 (Maino seed) |
| **`main`** | `34e518e` — perf(board): reduce LiveView load (#104) |
| **Latest tag** | **v0.1.3** (2026-08-02) — governance floor |
| **Unreleased on main** | Run console (#43/#47), CI resume+circuit (#44/#60, default off), trust/perf wave (#83–#96, #102–#104) |
| **Open PRs** | [#101](https://github.com/svarm-dev/svarm/pull/101) docs: post-0.1.3 Status + CHANGELOG; scrub weak APPROVALS example |
| **Focus (code)** | **[#48](https://github.com/svarm-dev/svarm/issues/48)** thin toolchain preflight + shared agent skills schema |
| **Next (code)** | [#49](https://github.com/svarm-dev/svarm/issues/49) typed stream · [#50](https://github.com/svarm-dev/svarm/issues/50) review-changes resume |
| **Parallel (small)** | Soft budget hold [#45](https://github.com/svarm-dev/svarm/issues/45) · ai-task hygiene [#97](https://github.com/svarm-dev/svarm/issues/97)–[#100](https://github.com/svarm-dev/svarm/issues/100) |
| **CI** | Assume green on `main` unless noted; check `gh pr checks` on your PR |

**Rank SoT (strategy):** vault `10 - Projects/Svärm/Index.md` (Obsidian). Do not re-rank from this file.

---

## Blocked (human / external)

_None known. Format: `YYYY-MM-DD · who · one sentence · link`_

---

## Session log (newest first, max ~10)

- 2026-08-10 · Maino · Seeded progress bus (STATUS.md + AGENTS protocol). Desk in vault Ops.
- 2026-08-10 · main · #104 board LiveView streams/projection; #103 runner/KanbanBridge tests; #102 sticky Basic Auth TTL

---

## Open delivery units (claim via GitHub, not chat)

**Product sequence (do not invent a parallel list):**

| Priority | Issue | Title |
|----------|-------|--------|
| NOW | [#48](https://github.com/svarm-dev/svarm/issues/48) | Thin toolchain preflight and shared agent skills schema |
| NEXT | [#49](https://github.com/svarm-dev/svarm/issues/49) | Typed stream events in the run console |
| NEXT | [#50](https://github.com/svarm-dev/svarm/issues/50) | Resume when reviewers request changes |
| Queued | [#51](https://github.com/svarm-dev/svarm/issues/51) | Mid-run Q&A |
| Parallel | [#45](https://github.com/svarm-dev/svarm/issues/45) | Soft budget mode (hold over cap) |

**ai-task hygiene (parallel, small):** #97 compose cookies · #98 .env.example · #99 Redact JWT · #100 dashboard wall-clock cost windows

Full list: `gh issue list --state open`

---

## Protocol (one page)

1. **Code work = GitHub issue** — never “tell Pi/Maino in chat only.”
2. **One issue → one branch → one PR** with `Closes #N`. Human merges.
3. **PR body:** include `## For Maino` only if strategy/fence/positioning needs a non-coder.
4. **After meaningful code session:** update Snapshot + one Session log line here.
5. **Non-code handoffs** (vault/launch): vault `Ops/Agent Desk.md` — not this file.
