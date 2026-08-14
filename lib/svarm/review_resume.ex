defmodule Svarm.ReviewResume do
  @moduledoc """
  Policy for GitHub "changes requested" detection.

  Pure evaluation: given durable coordination + a Reviews summary, returns
  whether the orchestrator should record or clear pending review-resume state.
  Does **not** spawn. Resume/re-dispatch is issue #113.
  """

  @type decision :: :noop | :record | :clear

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
  Build a short context string for a later resume prompt from a Reviews summary.
  Stored on detection; spawn is issue #113.
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
end
