defmodule Svarm.Toolchain do
  @moduledoc """
  PATH-only preflight for agent-declared host tools.

  Operators list expected executables on each agent (`tools` in `agents.toml` /
  Settings). Before spawn, Svärm checks each name with a cheap lookup
  (`System.find_executable/1` by default) — no model or API spend.

  Missing tools use `tools_mode`:

  - **`fail`** (default) — do not start the agent; mark the task failed with a
    clear board line
  - **`warn`** — allow spawn but surface a note that the agent expects those tools

  Omitted or empty `tools` is a no-op. Svärm never installs runtimes.

  See [docs/agents.md](../../docs/agents.md).
  """

  @type mode :: :fail | :warn

  @type result ::
          :ok
          | {:warn, [String.t()], String.t()}
          | {:error, :toolchain_missing, [String.t()], String.t()}

  @doc """
  Check that every declared tool is present on PATH.

  `agent_config` uses:

  - `:tools` — list of executable name strings (optional, default `[]`)
  - `:tools_mode` — `:fail` | `:warn` (optional, default `:fail`)

  Options:

  - `:lookup` — `(String.t() -> String.t() | nil)`, default `System.find_executable/1`.
    Tests inject a fake lookup so PATH need not be mutated.
  """
  @spec check(map(), keyword()) :: result()
  def check(agent_config, opts \\ []) when is_map(agent_config) do
    tools = normalize_tools(Map.get(agent_config, :tools))
    mode = normalize_mode(Map.get(agent_config, :tools_mode))
    lookup = Keyword.get(opts, :lookup, &System.find_executable/1)

    case missing_tools(tools, lookup) do
      [] ->
        :ok

      missing when mode == :warn ->
        msg = format_missing(missing, :warn)
        {:warn, missing, msg}

      missing ->
        msg = format_missing(missing, :fail)
        {:error, :toolchain_missing, missing, msg}
    end
  end

  @doc """
  Normalize a raw `tools` value from TOML or Settings to a list of trimmed
  non-empty tool name strings. Non-lists and non-string entries are dropped.
  """
  @spec normalize_tools(term()) :: [String.t()]
  def normalize_tools(nil), do: []

  def normalize_tools(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
  end

  def normalize_tools(_), do: []

  @doc """
  Normalize fail/warn policy. Unknown or omitted values become `:fail`.
  """
  @spec normalize_mode(term()) :: mode()
  def normalize_mode(:warn), do: :warn
  def normalize_mode("warn"), do: :warn
  def normalize_mode(:fail), do: :fail
  def normalize_mode("fail"), do: :fail
  def normalize_mode(_), do: :fail

  @doc "Human-readable board/log line for a missing-tools result."
  @spec format_missing([String.t()], mode()) :: String.t()
  def format_missing(missing, mode) when is_list(missing) and mode in [:fail, :warn] do
    names = Enum.join(missing, ", ")

    case mode do
      :fail ->
        "this agent expects tools on PATH that are missing: #{names} (tools_mode=fail; run not started)"

      :warn ->
        "this agent expects tools on PATH that are missing: #{names} (tools_mode=warn; starting anyway)"
    end
  end

  defp missing_tools(tools, lookup) do
    Enum.reject(tools, fn name ->
      case lookup.(name) do
        path when is_binary(path) and path != "" -> true
        _ -> false
      end
    end)
  end
end
