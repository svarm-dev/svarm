defmodule Svarm.Test.Wait do
  @moduledoc """
  Polling helpers for async GenServer / worker effects in tests.

  Prefer `:sys.get_state/1` as a sync barrier after a single orchestrator
  message when the assertion only needs that `handle_info` to finish.
  Use `until/2` when waiting on workers, PubSub, or multi-step outcomes.
  """

  @default_attempts 120
  @default_interval_ms 25

  @doc """
  Poll `fun` until it returns a truthy value or attempts are exhausted.

  Returns the last truthy value, or `false` on timeout.
  Default budget is ~3s (120 × 25ms) under CI load.
  """
  def until(fun, opts \\ []) when is_function(fun, 0) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    Enum.reduce_while(1..attempts, false, fn _, _ ->
      case fun.() do
        falsy when falsy in [false, nil] ->
          Process.sleep(interval_ms)
          {:cont, false}

        truthy ->
          {:halt, truthy}
      end
    end)
  end
end
