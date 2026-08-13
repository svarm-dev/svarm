# Typed stream events (v1)

> **Audience:** maintainers and coding agents implementing Events / RunLog / BoardLive.  
> **Code contract:** [`Svarm.StreamEvent`](../lib/svarm/stream_event.ex) — kind names and pure helpers.  
> **Epic:** [#49](https://github.com/svarm-dev/svarm/issues/49) · kinds locked in [#109](https://github.com/svarm-dev/svarm/issues/109) · Events/RunLog projection [#110](https://github.com/svarm-dev/svarm/issues/110) · Board chrome [#111](https://github.com/svarm-dev/svarm/issues/111).

Events emit typed v1 events on the live path, and BoardLive gives narrative, tool lifecycle, failure, and run-marker entries distinct chrome. RunLog stores a **text projection** (no kind column); late join and re-selection classify stable projected forms into the same chrome.

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
- `new/2` — build `%{kind, payload}`
- `to_text/1` — RunLog / BoardLive text projection

Do **not** invent alternate spellings (`tool_fail` as a separate kind, `stdout`, `marker`, …) in new typed emission paths. Prefer `tool_end` with a fail status on the payload.

## Transition note

`Svarm.Runner.LogFormat.tool_start/2` and `tool_fail/2` remain the **text projection** for tool events. Live path broadcasts `{:stream_event, task_id, event}` from `Events.broadcast_stream_event/2`; BoardLive ignores the paired compatibility `{:agent_line, ...}` tuple so entries append once. `broadcast_agent_line/2` is a `:text` stream event. Run start/finish emit `:run_marker` plus the existing `{:run_started, ...}` / `{:run_finished, ...}` tuples.

Successful `tool_end` events have no durable text projection, so their completion chip is live-only. Tool starts, failures, narrative text, and run markers restore from RunLog. There is no RunLog kind column or separate log product.

## Related modules (today)

| Module | Role today |
|--------|------------|
| `Svarm.StreamEvent` | Kind contract, `new/2`, `to_text/1` |
| `Svarm.Events` | PubSub + single-writer RunLog append (`stream_event`, `agent_line`, run started/finished) |
| `Svarm.RunLog` | Durable transcript **text** (no kind column) |
| `Svarm.Runner.LogFormat` | Pure text projections for tool start/fail |
| `SvarmWeb.BoardLive` | Typed live chrome + compatible text-projection restore |
