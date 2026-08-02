defmodule Svarm.Usage.Export do
  @moduledoc """
  Pure formatters for usage ledger export (JSON / CSV).

  Read-only — never updates or deletes ledger rows.
  Cost columns use `Usage.Query.cost_for_record/1` preference order.
  """

  alias Svarm.Usage.Query

  @csv_headers [
    "task_id",
    "run_id",
    "source",
    "provider",
    "model_id",
    "prompt_tokens",
    "completion_tokens",
    "cost_usd",
    "estimated",
    "recorded_at",
    "inserted_at"
  ]

  @doc "Serialize records to CSV (with header row)."
  @spec to_csv([map() | struct()]) :: String.t()
  def to_csv(records) when is_list(records) do
    rows = Enum.map(records, &csv_row/1)
    ([@csv_headers] ++ rows) |> Enum.map_join("\n", &csv_line/1) |> Kernel.<>("\n")
  end

  @doc "Serialize records to a JSON array string."
  @spec to_json([map() | struct()]) :: String.t()
  def to_json(records) when is_list(records) do
    records
    |> Enum.map(&json_row/1)
    |> Jason.encode!(pretty: true)
  end

  defp csv_row(record) do
    row = json_row(record)

    [
      row.task_id,
      row.run_id,
      row.source,
      row.provider,
      row.model_id,
      row.prompt_tokens,
      row.completion_tokens,
      row.cost_usd,
      row.estimated,
      row.recorded_at,
      row.inserted_at
    ]
  end

  defp json_row(record) do
    cost =
      case Query.cost_for_record(record) do
        {:ok, c} -> Float.round(c * 1.0, 6)
        _ -> nil
      end

    estimated? = Query.estimated_record?(record)

    %{
      task_id: field(record, :task_id),
      run_id: field(record, :run_id),
      source: field(record, :source),
      provider: field(record, :provider),
      model_id: field(record, :model_id),
      prompt_tokens: field(record, :prompt_tokens),
      completion_tokens: field(record, :completion_tokens),
      cost_usd: cost,
      estimated: estimated?,
      recorded_at: field(record, :recorded_at),
      inserted_at: format_dt(field(record, :inserted_at))
    }
  end

  defp field(%{__struct__: _} = rec, key), do: Map.get(rec, key)
  defp field(rec, key) when is_map(rec), do: Map.get(rec, key) || Map.get(rec, to_string(key))

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_dt(other), do: other

  defp csv_line(fields) do
    Enum.map_join(fields, ",", &csv_escape/1)
  end

  defp csv_escape(nil), do: ""
  defp csv_escape(true), do: "true"
  defp csv_escape(false), do: "false"
  defp csv_escape(n) when is_number(n), do: to_string(n)

  defp csv_escape(s) do
    s = to_string(s)

    if String.contains?(s, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end
end
