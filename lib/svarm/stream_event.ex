defmodule Svarm.StreamEvent do
  @moduledoc """
  V1 typed stream event kinds for the run console.

  Events, RunLog, and BoardLive share this contract so coding agents implement
  one set of kind names instead of inventing string labels per adapter.

  Human-oriented notes: [docs/typed-stream.md](../../docs/typed-stream.md).

  ## V1 kinds

  | Kind | Meaning |
  |------|---------|
  | `text` | Free-form agent stdout / narrative chunk |
  | `tool_start` | A tool call began (name + optional args summary) |
  | `tool_end` | A tool call finished (success or fail via payload status) |
  | `run_marker` | Run lifecycle banner (started / finished / attempt) |

  ## Transition (this slice)

  Runners may still project tool activity through
  `Svarm.Runner.LogFormat.tool_start/2` and `tool_fail/2` as **plain text lines**
  (`Events.broadcast_agent_line/2`). Those text projections may remain until
  Events/RunLog adopt typed emission (#110). This module does **not** change
  BoardLive chrome, RunLog schema, or governance run-marks product.
  """

  @typedoc "Atom form of a v1 stream event kind."
  @type kind :: :text | :tool_start | :tool_end | :run_marker

  @kinds [:text, :tool_start, :tool_end, :run_marker]

  # Whitelist only — never String.to_atom/1 on external input (AGENTS.md).
  @kind_by_string %{
    "text" => :text,
    "tool_start" => :tool_start,
    "tool_end" => :tool_end,
    "run_marker" => :run_marker
  }

  @doc """
  Ordered list of v1 kind atoms.

  Use this (or `kind?/1` / `parse_kind/1`) when emitting or validating events.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "True when `kind` is a known v1 kind (atom or string name)."
  @spec kind?(term()) :: boolean()
  def kind?(kind) when kind in @kinds, do: true
  def kind?(kind) when is_binary(kind), do: Map.has_key?(@kind_by_string, kind)
  def kind?(_), do: false

  @doc """
  Parse a kind from an atom or string into the canonical atom form.

  Returns `{:ok, kind}` or `:error`. Safe for external input (whitelist only).
  """
  @spec parse_kind(term()) :: {:ok, kind()} | :error
  def parse_kind(kind) when kind in @kinds, do: {:ok, kind}

  def parse_kind(kind) when is_binary(kind) do
    case Map.fetch(@kind_by_string, kind) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  def parse_kind(_), do: :error

  @doc "String name for a v1 kind atom, or `nil` if not a v1 kind."
  @spec kind_string(term()) :: String.t() | nil
  def kind_string(kind) when kind in @kinds, do: Atom.to_string(kind)
  def kind_string(_), do: nil
end
