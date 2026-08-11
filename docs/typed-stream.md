# Typed stream events (v1)

> **Audience:** maintainers and coding agents implementing Events / RunLog / BoardLive.  
> **Code contract:** [`Svarm.StreamEvent`](../lib/svarm/stream_event.ex) — kind names and pure helpers.  
> **Epic:** [#49](https://github.com/svarm-dev/svarm/issues/49) · this doc locks kinds for [#109](https://github.com/svarm-dev/svarm/issues/109).

Run console output is still largely **line-soup** today. Before BoardLive chrome (#111) or Events/RunLog projection (#110), v1 **event kinds** are locked so every layer shares one name set.

## V1 kinds

| Kind | Atom | Role |
|------|------|------|
| `text` | `:text` | Free-form agent stdout / narrative chunk |
| `tool_start` | `:tool_start` | Tool call began (name + optional args summary) |
| `tool_end` | `:tool_end` | Tool call finished — success **or** fail (status on payload) |
| `run_marker` | `:run_marker` | Run lifecycle (started / finished / attempt banner) |

Implement against `Svarm.StreamEvent`:

- `kinds/0` — ordered v1 kind list
- `kind?/1` — membership check (atom or string)
- `parse_kind/1` — external-safe parse → `{:ok, kind}` or `:error`
- `kind_string/1` — atom → string name

Do **not** invent alternate spellings (`tool_fail` as a separate kind, `stdout`, `marker`, …) in new typed emission paths. Prefer `tool_end` with a fail status on the payload.

## Transition note

`Svarm.Runner.LogFormat.tool_start/2` and `tool_fail/2` **text line projections may remain** during transition. Runners still call `Events.broadcast_agent_line/2` with those strings; RunLog stores opaque text. Typed emission and late-join restore are **#110**. BoardLive visual redesign is **#111**.

This slice does **not** require:

- BoardLive console chrome
- RunLog schema migration (prefer defer)
- Governance run-marks product

## Related modules (today)

| Module | Role today |
|--------|------------|
| `Svarm.Events` | PubSub + single-writer RunLog append (`agent_line`, run started/finished) |
| `Svarm.RunLog` | Durable transcript text (no kind column yet) |
| `Svarm.Runner.LogFormat` | Pure text projections for tool start/fail |
