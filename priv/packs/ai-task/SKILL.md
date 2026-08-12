---
name: ai-task
description: Work a Svärm-dispatched issue ticket end to end — read repo conventions first, keep scope to the ticket, verify with the project's own gate, and open a clean PR. Use whenever a task arrives from the Svärm board.
---

# Working a board ticket

You were dispatched by Svärm on a single ticket. The run prompt (from the
repo's WORKFLOW.md) covers mechanics — clone, branch, push, open a PR. This
pack is the repo-citizenship layer on top: the conventions that keep your PR
mergeable. It is harness-agnostic; your runner only wraps how you are started.

## Before you edit

1. Read the repo's `AGENTS.md` (the closest one to your edits wins) and
   `STATUS.md` if present. Repo conventions override generic habits.
2. Re-read the ticket. Its acceptance criteria are the whole scope — implement
   exactly what it asks. No drive-by refactors, no "while I'm here" work.

## While you work

- One ticket → one branch → one PR.
- Follow the repo's branch naming, commit style, and code conventions (from
  its `AGENTS.md`), not your defaults.
- Keep secrets, tokens, and local paths out of commits, logs, and PR text.

## Before you push

- Run the verification gate the repo's docs name — its tests, linter, and
  formatter (for example `mix precommit` in an Elixir repo). Fix what it
  flags. Do not push red and leave CI for the maintainer.

## The PR

- Reference the ticket with `Closes #N` (or `Fixes #N`) in the PR body.
- Summarize what changed and how you verified it.
- Never merge, never push to the default branch. Humans keep merge.

## If blocked

Stop and comment on the issue with what you need (access, decision,
clarification) instead of guessing or widening scope.
