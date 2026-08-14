defmodule Svarm.CiResume do
  @moduledoc """
  Policy for CI-failure re-dispatch and circuit breaker.

  Pure evaluation: given durable coordination + Checks summary + caps,
  returns what the orchestrator should do. Default **disabled**.
  """

  alias Svarm.Workflow.Env

  @type caps :: %{
          enabled: boolean(),
          max_attempts: pos_integer(),
          skip_draft: boolean()
        }

  @type decision :: :noop | :wait | :resume | :circuit_open

  @default_max_attempts 3

  @doc """
  Load CI resume caps from process env and optional WORKFLOW front matter.

  Env:
  - `SVARM_CI_RESUME_ENABLED` — `true`/`1`/`yes` enables
  - `SVARM_CI_RESUME_MAX_ATTEMPTS` — integer (default 3)

  WORKFLOW:
  ```yaml
  ci_resume:
    enabled: false
    max_attempts: 3
    skip_draft: true
  ```

  When both env and workflow set a field, env wins for enabled/max_attempts.
  """
  @spec load_caps(map() | nil) :: caps()
  def load_caps(workflow_config \\ nil) do
    wf = workflow_ci(workflow_config)

    %{
      enabled: Env.env_bool("SVARM_CI_RESUME_ENABLED", Map.get(wf, :enabled, false)),
      max_attempts:
        Env.env_int(
          "SVARM_CI_RESUME_MAX_ATTEMPTS",
          Map.get(wf, :max_attempts, @default_max_attempts)
        ),
      skip_draft: Map.get(wf, :skip_draft, true)
    }
  end

  @doc """
  Decide next action for one task.

  - `:noop` — disabled, no PR, already handled this sha, or passed
  - `:wait` — CI in progress or draft skip
  - `:resume` — failed, under N, new head_sha
  - `:circuit_open` — failed and resume count already >= max_attempts
  """
  @spec evaluate(map() | nil, map() | nil, caps()) :: decision()
  def evaluate(_coord, _summary, %{enabled: false}), do: :noop
  def evaluate(nil, _summary, _caps), do: :noop
  def evaluate(_coord, nil, _caps), do: :noop

  def evaluate(coord, summary, caps) when is_map(coord) and is_map(summary) do
    if map_get(coord, :ci_circuit_open) == true do
      :noop
    else
      do_evaluate(coord, summary, caps)
    end
  end

  defp do_evaluate(coord, summary, caps) do
    conclusion = map_get(summary, :conclusion)
    head_sha = map_get(summary, :head_sha)
    count = map_get(coord, :ci_resume_count) || 0
    last_sha = map_get(coord, :ci_last_head_sha)
    max_n = caps.max_attempts || @default_max_attempts

    case conclusion do
      c when c in [:pending, :in_progress] -> :wait
      :passed -> :noop
      :failed -> failed_decision(count, max_n, last_sha, head_sha)
      _ -> :noop
    end
  end

  defp failed_decision(_count, _max_n, last_sha, head_sha)
       when is_binary(last_sha) and last_sha == head_sha,
       do: :noop

  defp failed_decision(count, max_n, _last_sha, _head_sha) when count >= max_n,
    do: :circuit_open

  defp failed_decision(_count, _max_n, _last_sha, _head_sha), do: :resume

  defp map_get(%{__struct__: _} = struct, key), do: Map.get(struct, key)
  defp map_get(map, key) when is_map(map), do: Map.get(map, key)

  @doc """
  Build a short context string for the next agent prompt from a Checks summary.
  """
  @spec context_summary(map()) :: String.t()
  def context_summary(summary) when is_map(summary) do
    base = Map.get(summary, :summary) || "CI failed"
    names = Map.get(summary, :failed_names) || []
    sha = Map.get(summary, :head_sha)

    [
      "## CI feedback (auto-resume)",
      "",
      base,
      "",
      failed_names_block(names),
      sha_block(sha),
      "Fix the failures on this PR branch, push, and leave the ticket ready for human review.",
      "Do not merge."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp failed_names_block([]), do: ""

  defp failed_names_block(names) do
    "Failed checks:\n" <> Enum.map_join(names, "\n", &"- #{&1}") <> "\n"
  end

  defp sha_block(sha) when is_binary(sha), do: "Head SHA: `#{sha}`\n"
  defp sha_block(_), do: ""

  defp workflow_ci(nil), do: %{}

  defp workflow_ci(config) when is_map(config) do
    case Map.get(config, "ci_resume") do
      m when is_map(m) -> parse_workflow_ci(m)
      _ -> %{}
    end
  end

  defp parse_workflow_ci(m) do
    %{
      enabled: Env.truthy?(Map.get(m, "enabled")),
      max_attempts: Env.parse_int(Map.get(m, "max_attempts")),
      skip_draft: Map.get(m, "skip_draft", true) != false
    }
    |> Env.reject_nil()
  end
end
