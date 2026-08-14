defmodule Svarm.ReviewResume do
  @moduledoc """
  Policy for GitHub "changes requested" detection and optional re-dispatch.

  Detection is always-on for the GitHub tracker. Spawn is **off by default**
  (`review_resume.enabled` / `SVARM_REVIEW_RESUME_ENABLED`). When enabled,
  the first transition into changes-requested re-opens the ticket for a
  fresh agent run. Later `:record` on a new SHA in the same episode is
  detection only — GitHub does not clear `CHANGES_REQUESTED` on push.

  Spawn shares `ci_resume_count` / `ci_circuit_open` and the CI resume
  `max_attempts` cap. See `Svarm.CiResume`.
  """

  @type decision :: :noop | :record | :clear
  @type spawn_decision :: :noop | :resume | :circuit_open

  @type caps :: %{enabled: boolean()}

  @type spawn_caps :: %{
          enabled: boolean(),
          max_attempts: pos_integer()
        }

  @default_max_attempts 3

  @doc """
  Load review-resume spawn caps from process env and optional WORKFLOW front matter.

  Env:
  - `SVARM_REVIEW_RESUME_ENABLED` — `true`/`1`/`yes` enables spawn

  WORKFLOW:
  ```yaml
  review_resume:
    enabled: false
  ```

  When both env and workflow set `enabled`, env wins. Detection does not
  use this flag.
  """
  @spec load_caps(map() | nil) :: caps()
  def load_caps(workflow_config \\ nil) do
    wf = workflow_review(workflow_config)

    %{
      enabled: env_bool("SVARM_REVIEW_RESUME_ENABLED", Map.get(wf, :enabled, false))
    }
  end

  @doc """
  Decide whether to persist review-resume detection for one task.

  - `:noop` — nothing new (no summary, already recorded this sha+decision, or never requested)
  - `:record` — latest submitted review is changes-requested (new or sha moved)
  - `:clear` — previously recorded changes-requested, latest reviews no longer are
  """
  @spec evaluate(map() | nil, map() | nil) :: decision()
  def evaluate(_coord, nil), do: :noop
  def evaluate(nil, summary), do: evaluate(%{}, summary)

  def evaluate(coord, summary) when is_map(coord) and is_map(summary) do
    case map_get(summary, :decision) do
      :changes_requested -> record_or_noop(coord, summary)
      _ -> clear_or_noop(coord)
    end
  end

  defp record_or_noop(coord, summary) do
    sha = map_get(summary, :head_sha)

    if map_get(coord, :review_decision) == "changes_requested" and
         map_get(coord, :review_last_head_sha) == sha do
      :noop
    else
      :record
    end
  end

  defp clear_or_noop(coord) do
    if map_get(coord, :review_decision) == "changes_requested" do
      :clear
    else
      :noop
    end
  end

  @doc """
  Decide whether to re-open a ticket after a detection decision.

  Call with the **pre-upsert** coordination row. After `:record` is persisted,
  `review_decision` is already `"changes_requested"`, so a later SHA refresh
  would look like a new episode if we read the post-upsert row.

  - `:noop` — disabled, not a `:record`, already in this episode, or circuit open
  - `:resume` — first transition into changes-requested, under the shared cap
  - `:circuit_open` — first transition but shared resume count already >= max
  """
  @spec spawn_evaluate(map() | nil, decision(), spawn_caps()) :: spawn_decision()
  def spawn_evaluate(_coord, _detection, %{enabled: false}), do: :noop
  def spawn_evaluate(_coord, detection, _caps) when detection != :record, do: :noop
  def spawn_evaluate(nil, :record, _caps), do: :noop

  def spawn_evaluate(coord, :record, caps) when is_map(coord) do
    cond do
      map_get(coord, :review_decision) == "changes_requested" ->
        :noop

      map_get(coord, :ci_circuit_open) == true ->
        :noop

      (map_get(coord, :ci_resume_count) || 0) >= max_attempts(caps) ->
        :circuit_open

      true ->
        :resume
    end
  end

  defp max_attempts(%{max_attempts: n}) when is_integer(n) and n > 0, do: n
  defp max_attempts(_), do: @default_max_attempts

  @doc """
  Build a short context string for a resume prompt from a Reviews summary.
  Stored on detection; injected into the next agent prompt when spawn runs.
  """
  @spec context_summary(map()) :: String.t()
  def context_summary(summary) when is_map(summary) do
    base = Map.get(summary, :summary) || "Changes requested"
    logins = Map.get(summary, :reviewer_logins) || []
    sha = Map.get(summary, :head_sha)

    [
      "## Review feedback (changes requested)",
      "",
      base,
      "",
      reviewers_block(logins),
      sha_block(sha),
      "Address the requested changes on this PR branch, push, and leave the ticket ready for human review.",
      "Do not merge."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp reviewers_block([]), do: ""

  defp reviewers_block(logins) do
    "Reviewers:\n" <> Enum.map_join(logins, "\n", &"- #{&1}") <> "\n"
  end

  defp sha_block(sha) when is_binary(sha), do: "Head SHA: `#{sha}`\n"
  defp sha_block(_), do: ""

  defp map_get(%{__struct__: _} = struct, key), do: Map.get(struct, key)
  defp map_get(map, key) when is_map(map), do: Map.get(map, key)

  defp workflow_review(nil), do: %{}

  defp workflow_review(config) when is_map(config) do
    case Map.get(config, "review_resume") do
      m when is_map(m) -> parse_workflow_review(m)
      _ -> %{}
    end
  end

  defp parse_workflow_review(m) do
    %{enabled: truthy?(Map.get(m, "enabled"))}
    |> reject_nil()
  end

  defp env_bool(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      v -> String.downcase(v) in ~w(1 true yes on)
    end
  end

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp reject_nil(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
