defmodule Svarm.Tracker.NormalizeSupport do
  @moduledoc false
  # Shared issue-normalization bits. Kept here so tracker adapters do not
  # copy the same Coordination overlay and ISO parsing (ex_dna clone budget is 0).

  alias Svarm.{Coordination, Issue}

  @doc "Overlay durable retry counters. Missing rows stay at 0."
  @spec attach_attempts(Issue.t() | [Issue.t()]) :: Issue.t() | [Issue.t()]
  def attach_attempts(%Issue{} = issue) do
    [overlaid] = attach_attempts([issue])
    overlaid
  end

  def attach_attempts(issues) when is_list(issues) do
    by_id = Coordination.get_many(Enum.map(issues, & &1.id))

    Enum.map(issues, fn issue ->
      case Map.get(by_id, issue.id) do
        %{attempts: n} when is_integer(n) and n >= 0 -> %{issue | attempts: n}
        _ -> issue
      end
    end)
  end

  @doc "Unix seconds from an ISO-8601 timestamp, or 0."
  @spec created_unix(term()) :: integer()
  def created_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  def created_unix(_), do: 0
end
