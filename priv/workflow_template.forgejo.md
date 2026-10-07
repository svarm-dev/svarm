---
# tracker: local board (Kaneo lands separately under #263)
tracker:
  kind: local
  active_states: ["todo", "in_progress"]
  terminal_states: ["done", "failed", "review"]

polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 3
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 2700000
approval:
  mode: untrusted
  trusted_assignees: ["default", "demo_research", "demo_docs"]
# Separate code remote (Forgejo). Setting git_remote selects clone isolation:
# Svärm clones with plain `git` (no `gh`) and configures a credential helper
# that reads GIT_TOKEN for the agent's push. The token is never written to
# .git/config. Put FORGEJO_TOKEN in .env and keep the `$` reference here.
workspace:
  root: ~/svarm_workspaces
  git_remote: https://git.example.com/org/repo.git
  git_token: $FORGEJO_TOKEN
---

You are an autonomous engineer. Complete the task below on a new branch,
verify, push, and stop. Do **not** merge.

Workflow:
1. The repo is already cloned in this workspace; `origin` is the configured
   Forgejo remote. Do not re-clone it.
2. Create a branch: `git checkout -b svarm/{{issue.source_id}}`
3. Implement the changes described below
4. Run project tests and lint if present; if they fail, exit non-zero
5. Commit with a descriptive message referencing the issue
6. Push: `git push -u origin HEAD`
7. Open a pull request against the default branch (Forgejo web UI or API),
   or leave the pushed branch and summarize for human review
8. Summarize what you changed and what you verified
9. Do **not** merge the PR and do **not** push to main/master

Task: {{issue.title}} (issue #{{issue.source_id}}, id {{issue.id}})
Attempt: {{attempt}}

Description:
{{issue.description}}
