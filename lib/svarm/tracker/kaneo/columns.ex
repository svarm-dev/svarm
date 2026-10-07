defmodule Svarm.Tracker.Kaneo.Columns do
  @moduledoc """
  Maps orchestrator statuses onto Kaneo column slugs.

  A stock Kaneo project uses `to-do`, `in-progress`, `in-review`, and `done`.
  Svärm still speaks `todo`, `in_progress`, `review`, `done`, `failed`, and
  `pending_approval`. `column_slugs` in the tracker config overrides any
  default. `pending_approval` defaults to `pending-approval`, which a stock
  board does not have — `update_status/3` fails closed until that column
  exists or the operator points the status at one that does.
  """

  @default_slugs %{
    "todo" => "to-do",
    "in_progress" => "in-progress",
    "review" => "in-review",
    "done" => "done",
    "failed" => "failed",
    "pending_approval" => "pending-approval"
  }

  @doc "Kaneo column slug for an orchestrator status."
  @spec to_slug(term(), map()) :: term()
  def to_slug(status, config) when is_binary(status) do
    Map.get(slug_map(config), status, status)
  end

  def to_slug(status, _config), do: status

  @doc "Orchestrator status for a Kaneo column slug. Unknown slugs pass through."
  @spec to_status(term(), map()) :: term()
  def to_status(slug, config) when is_binary(slug) do
    Enum.find_value(slug_map(config), slug, fn {status, column} ->
      if column == slug, do: status
    end)
  end

  def to_status(slug, _config), do: slug

  defp slug_map(config) when is_map(config) do
    custom =
      config
      |> Map.get(:column_slugs, %{})
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)

    Map.merge(@default_slugs, custom)
  end

  defp slug_map(_), do: @default_slugs
end
