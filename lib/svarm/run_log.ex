defmodule Svarm.RunLog do
  @moduledoc """
  Persistent run log storage backed by SQLite.

  Stream chunks are coalesced in `Svarm.RunLog.Buffer` and flushed with a
  SQL `content || ?` append so the hot path never reads the full transcript
  back into BEAM for every delta. `get/1` reconstructs durable content plus
  any pending buffer so board late-join stays complete.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Svarm.Repo
  alias Svarm.RunLog.Buffer

  schema "run_logs" do
    field(:task_id, :string)
    field(:content, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Append a chunk to a task's log.

  Single persist-path redact: secrets are scrubbed here before any buffering
  or durable write, so callers that skip `Events` stay fail-closed.
  `Events.persist_agent_line/2` must not call `Redact.text/1` again.
  Creates the row on first flush if it does not exist.
  """
  def append(task_id, chunk) when is_binary(task_id) and is_binary(chunk) do
    chunk = Svarm.Redact.text(chunk)
    Buffer.append(task_id, chunk)
    :ok
  end

  @doc "Get the full log for a task (durable + pending buffer), or empty string."
  def get(task_id) when is_binary(task_id) do
    durable_content(task_id) <> Buffer.pending(task_id)
  end

  @doc "Force pending buffer for a task into SQLite (e.g. run finished)."
  def flush(task_id) when is_binary(task_id) do
    Buffer.flush(task_id)
  end

  @doc "Force every pending buffer into SQLite."
  def flush_all do
    Buffer.flush_all()
  end

  @doc false
  # Called only from Buffer on flush — chunk is already redacted.
  # SQL `content || ?` avoids loading the full transcript into BEAM.
  def persist_append(task_id, chunk)
      when is_binary(task_id) and is_binary(chunk) and chunk != "" do
    {n, _} = sql_append(task_id, chunk)

    if n == 0 do
      insert_or_append(task_id, chunk)
    end

    :ok
  end

  defp insert_or_append(task_id, chunk) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case %__MODULE__{task_id: task_id, content: chunk, inserted_at: now}
         |> Repo.insert(on_conflict: :nothing, conflict_target: :task_id) do
      {:ok, %{id: id}} when not is_nil(id) ->
        :ok

      {:ok, _} ->
        # Lost insert race — append so the chunk is not dropped.
        _ = sql_append(task_id, chunk)
        :ok

      {:error, _} ->
        _ = sql_append(task_id, chunk)
        :ok
    end
  end

  # `update:` must live inside `from/2` so fragment pins expand.
  defp sql_append(task_id, chunk) do
    from(r in __MODULE__,
      where: r.task_id == ^task_id,
      update: [set: [content: fragment("content || ?", ^chunk)]]
    )
    |> Repo.update_all([])
  end

  defp durable_content(task_id) do
    case Repo.one(from(r in __MODULE__, where: r.task_id == ^task_id, select: r.content)) do
      nil -> ""
      content when is_binary(content) -> content
    end
  end
end
