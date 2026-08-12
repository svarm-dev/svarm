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

  Events persist a **text projection** in RunLog (no kind column) so late-join
  stays compatible. Live path also broadcasts `{:stream_event, task_id, event}`.
  BoardLive chrome is #111.
  """

  alias Svarm.Runner.LogFormat

  @typedoc "Atom form of a v1 stream event kind."
  @type kind :: :text | :tool_start | :tool_end | :run_marker

  @typedoc "Typed stream event. Payload keys are atoms from internal constructors."
  @type event :: %{kind: kind(), payload: map()}

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

  @doc "Build a v1 event map. `kind` must be a v1 atom; payload is an atom-key map."
  @spec new(kind(), map()) :: event()
  def new(kind, payload \\ %{}) when kind in @kinds and is_map(payload) do
    %{kind: kind, payload: payload}
  end

  @doc """
  Project a typed event to the RunLog / BoardLive text line.

  Empty string means persist nothing (typed PubSub still fires). Tool lines
  reuse `LogFormat` so existing console text stays stable during #111.
  """
  @spec to_text(event()) :: String.t()
  def to_text(%{kind: :text, payload: payload}) do
    case payload[:text] do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  def to_text(%{kind: :tool_start, payload: payload}) do
    LogFormat.tool_start(tool_name(payload), payload[:args])
  end

  def to_text(%{kind: :tool_end, payload: payload}) do
    name = tool_name(payload)

    case payload[:status] do
      :error -> LogFormat.tool_fail(name, payload[:result])
      _ -> ""
    end
  end

  def to_text(%{kind: :run_marker, payload: payload}) do
    case payload[:phase] do
      :started ->
        "--- #{payload[:label] || "Agent started"} ---\n"

      :finished ->
        "\n--- run finished (exit #{payload[:exit_code] || "?"}) ---\n"

      _ ->
        ""
    end
  end

  def to_text(_), do: ""

  defp tool_name(payload) do
    case payload[:name] do
      name when is_binary(name) and name != "" -> name
      _ -> "tool"
    end
  end
end
