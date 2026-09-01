defmodule Svarm.Orchestrator.Issues do
  @moduledoc """
  Tick-scoped tracker issue lookup for the orchestrator.

  `get_issues/2` (when the adapter exports it) fills `state.issue_cache`
  so reconcile and `depends_on` gating share one batch. Callers must not
  treat a batch-level error as every id vanishing.
  """

  require Logger

  @doc false
  def prefetch(state, []), do: state

  def prefetch(state, ids) when is_list(ids) do
    missing =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(state.issue_cache || %{}, &1))

    case tracker_get_issues(state.tracker, state.tracker_config, missing) do
      {:ok, results} ->
        %{state | issue_cache: Map.merge(state.issue_cache || %{}, results)}

      {:error, reason} ->
        # Never copy a batch-level :not_found onto every id — that would
        # look like the whole in-flight set vanished. Wrap as tracker_error
        # so reconcile keeps work (same as a transient get_issue failure).
        wrapped = wrap_batch_error(reason)
        filled = Map.new(missing, fn id -> {id, wrapped} end)
        %{state | issue_cache: Map.merge(state.issue_cache || %{}, filled)}
    end
  end

  @doc false
  def lookup(state, id) do
    case Map.fetch(state.issue_cache || %{}, id) do
      {:ok, result} -> result
      :error -> get(state.tracker, state.tracker_config, id)
    end
  end

  @doc false
  def get(tracker, config, id) do
    tracker.get_issue(config, id)
  rescue
    e in [ArgumentError, KeyError, ErlangError] ->
      Logger.warning("reconcile_tracker get_issue failed for #{id}: #{inspect(e)}")
      {:error, {:tracker_error, e}}
  end

  defp wrap_batch_error({:tracker_error, _} = reason), do: {:error, reason}
  defp wrap_batch_error(reason), do: {:error, {:tracker_error, reason}}

  defp tracker_get_issues(_tracker, _config, []), do: {:ok, %{}}

  defp tracker_get_issues(tracker, config, ids) do
    _ = Code.ensure_loaded?(tracker)

    if function_exported?(tracker, :get_issues, 2) do
      safe_get_issues(tracker, config, ids)
    else
      {:ok, Map.new(ids, fn id -> {id, get(tracker, config, id)} end)}
    end
  end

  defp safe_get_issues(tracker, config, ids) do
    case tracker.get_issues(config, ids) do
      {:ok, results} when is_map(results) ->
        {:ok, fill_issue_results(tracker, config, ids, results)}

      {:error, reason} ->
        {:error, reason}

      other ->
        Logger.warning(
          "tracker get_issues returned #{inspect(Svarm.Redact.map(%{unexpected: other}))}"
        )

        {:error, {:tracker_error, :unexpected}}
    end
  end

  defp fill_issue_results(tracker, config, ids, results) do
    Map.new(ids, &issue_result(tracker, config, results, &1))
  end

  defp issue_result(tracker, config, results, id) do
    case Map.fetch(results, id) do
      {:ok, result} -> {id, result}
      :error -> {id, get(tracker, config, id)}
    end
  end
end
