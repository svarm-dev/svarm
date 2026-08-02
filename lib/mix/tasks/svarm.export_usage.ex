defmodule Mix.Tasks.Svarm.ExportUsage do
  @moduledoc """
  Export the append-only usage ledger as CSV or JSON.

      mix svarm.export_usage
      mix svarm.export_usage --format csv
      mix svarm.export_usage --format json --out /tmp/usage.json

  Defaults: format `csv`, write to stdout when `--out` is omitted.
  Read-only — never updates or deletes ledger rows.
  """
  use Mix.Task

  @shortdoc "Export usage ledger as CSV or JSON"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        switches: [format: :string, out: :string],
        aliases: [f: :format, o: :out]
      )

    format = opts |> Keyword.get(:format, "csv") |> String.downcase()
    out = Keyword.get(opts, :out)

    unless format in ["csv", "json"] do
      Mix.raise("Unknown format #{inspect(format)}; use csv or json")
    end

    Mix.Task.run("app.start")

    records = Svarm.Usage.Ledger.list_all()

    body =
      case format do
        "csv" -> Svarm.Usage.Export.to_csv(records)
        "json" -> Svarm.Usage.Export.to_json(records)
      end

    case out do
      nil ->
        IO.write(body)

      path ->
        File.write!(path, body)
        Mix.shell().info("Wrote #{length(records)} records to #{path} (#{format})")
    end
  end
end
