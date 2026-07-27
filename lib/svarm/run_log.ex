defmodule Svarm.RunLog do
  @moduledoc """
  Persistent run log storage backed by SQLite.

  Logs are appended line-by-line and stored in the database so they survive
  board reconnects, page refreshes, and server restarts.
  """
  use Ecto.Schema

  alias Svarm.Repo

  schema "run_logs" do
    field(:task_id, :string)
    field(:content, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Append a chunk to a task's log. Creates the row if it doesn't exist."
  def append(task_id, chunk) when is_binary(task_id) and is_binary(chunk) do
    chunk = Svarm.Redact.text(chunk)

    case Repo.get_by(__MODULE__, task_id: task_id) do
      nil ->
        %__MODULE__{task_id: task_id, content: chunk}
        |> Repo.insert!(on_conflict: :nothing)

      log ->
        log
        |> Ecto.Changeset.change(content: log.content <> chunk)
        |> Repo.update!()
    end
  end

  @doc "Get the full log for a task, or empty string."
  def get(task_id) do
    case Repo.get_by(__MODULE__, task_id: task_id) do
      nil -> ""
      log -> log.content
    end
  end
end
