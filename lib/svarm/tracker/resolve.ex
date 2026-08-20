defmodule Svarm.Tracker.Resolve do
  @moduledoc """
  Single kind → `{adapter_module, config}` path for every tracker consumer.

  Orchestrator, Board, Approval, Demo, Settings connectivity checks, runners,
  and Dispatch call this module. Do not map `:github` / `:local` to adapter
  modules at those call sites.

  ## Registering an adapter

  1. Implement `Svarm.Tracker` in `lib/svarm/tracker/<kind>.ex`.
  2. Add the kind atom to `@adapters` below.
  3. If the tracker has extras (CI Checks, PR reviews, a live connectivity
     probe), return them from `capabilities/0`. Local returns `[]`; adapters
     that omit `capabilities/0` keep CI/review polling (test doubles).
  4. Tests for the adapter. Do not fork the orchestrator.
  """

  alias Svarm.{Settings, Tracker, Workflow}
  alias Svarm.Workflow.Config, as: WorkflowConfig

  # Kind atoms shipped in OSS. A third tracker is one module + this map + tests.
  @adapters %{
    local: Tracker.Local,
    github: Tracker.GitHub
  }

  @default_active_states ["todo", "in_progress"]
  @default_terminal_states ["done", "failed", "review"]

  # When an adapter does not export capabilities/0, CI/review poll (same as
  # today's non-Local test doubles). Local declares `[]` to opt out.
  @undeclared_capabilities [:ci_poll, :review_poll]

  @doc """
  Active tracker from workflow + Settings overlay.

  Pass `:config` to skip the overlay (already-resolved maps, form probes).
  Pass `:active_states` / `:terminal_states` as Local fallbacks.
  """
  def adapter_and_config(opts \\ []) when is_list(opts) do
    tc =
      case Keyword.fetch(opts, :config) do
        {:ok, %{} = given} -> given
        :error -> active_config()
      end

    kind = normalize_kind(tc[:kind])
    adapter = adapter_module(kind)
    {adapter, prepare_config(kind, tc, opts)}
  end

  @doc "Workflow tracker map with Settings overlay applied."
  def active_config do
    Settings.Resolve.tracker_overlay(workflow_base())
  end

  @doc """
  Adapter module for a kind atom or string. Unknown kinds fall back to Local.
  """
  def adapter_module(kind) do
    Map.get(@adapters, normalize_kind(kind), Tracker.Local)
  end

  @doc """
  Resolve tracker from runner/Dispatch opts.

  Explicit `:tracker` wins (tests inject doubles). Otherwise the active
  adapter from `adapter_and_config/1`. Explicit `:tracker_config` wins
  over the resolved config.
  """
  def from_opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :tracker) do
      {:ok, adapter} when is_atom(adapter) ->
        {adapter, Keyword.get(opts, :tracker_config, %{})}

      :error ->
        {adapter, config} = adapter_and_config()
        {adapter, Keyword.get(opts, :tracker_config, config)}
    end
  end

  @doc """
  Whether `adapter` offers an extra beyond the core issue callbacks.

  Local returns `[]`. GitHub returns CI poll, review poll, and connectivity
  probe. Adapters that omit `capabilities/0` default to CI/review poll.
  """
  def supports?(adapter, cap) when is_atom(adapter) and is_atom(cap) do
    _ = Code.ensure_loaded?(adapter)

    caps =
      if function_exported?(adapter, :capabilities, 0) do
        List.wrap(adapter.capabilities())
      else
        @undeclared_capabilities
      end

    cap in caps
  end

  defp workflow_base do
    workflow = Workflow.Store.get()
    cfg = if workflow, do: WorkflowConfig.from(workflow), else: %{}
    cfg[:tracker_config] || %{kind: :local}
  end

  defp normalize_kind(:github), do: :github
  defp normalize_kind("github"), do: :github
  defp normalize_kind(:local), do: :local
  defp normalize_kind("local"), do: :local
  defp normalize_kind(_), do: :local

  defp prepare_config(:local, tc, opts) do
    %{
      kind: :local,
      active_states:
        tc[:active_states] || Keyword.get(opts, :active_states, @default_active_states),
      terminal_states:
        tc[:terminal_states] || Keyword.get(opts, :terminal_states, @default_terminal_states),
      ignored_assignees: Map.get(tc, :ignored_assignees, [])
    }
  end

  defp prepare_config(_kind, tc, _opts) do
    Map.put(tc, :kind, normalize_kind(tc[:kind]))
  end
end
