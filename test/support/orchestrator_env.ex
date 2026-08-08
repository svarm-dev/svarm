defmodule Svarm.Test.OrchestratorEnv do
  @moduledoc """
  Capture/restore Application env keys that Demo.seed and isolated board tests mutate.

  Those keys are process-global for the whole suite; without restore, a 2s poll or
  max_concurrent pin leaks into later modules and races LiveView assertions.
  """

  @keys [
    :orchestrator_poll_interval_ms,
    :orchestrator_max_concurrent,
    :orchestrator_workspace_root,
    :approval_overlay
  ]

  @doc "Snapshot current orchestrator-related Application env values."
  def capture do
    Map.new(@keys, fn key -> {key, Application.get_env(:svarm, key)} end)
  end

  @doc """
  Restore a snapshot from `capture/0` and reload Orchestrator config when running.

  Prefer `restore_on_exit/0` in test setup so cleanup runs even on failure.
  """
  def restore(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn {key, val} -> restore_key(key, val) end)

    if Process.whereis(Svarm.Orchestrator) do
      _ = Svarm.Orchestrator.reload_config()
    end

    :ok
  end

  @doc """
  Capture now and register `on_exit` restore. Returns the snapshot.

  Call from `setup` (or a single test) before any put_env that must not leak.
  """
  def restore_on_exit do
    snapshot = capture()
    ExUnit.Callbacks.on_exit(fn -> restore(snapshot) end)
    snapshot
  end

  defp restore_key(key, nil), do: Application.delete_env(:svarm, key)
  defp restore_key(key, val), do: Application.put_env(:svarm, key, val)
end
