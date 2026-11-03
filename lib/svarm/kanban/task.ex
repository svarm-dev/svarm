defmodule Svarm.Kanban.Task do
  @moduledoc """
  Ecto schema for kanban tasks — the issue tracker backing Svärm's Symphony loop.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "tasks" do
    field(:title, :string)
    field(:body, :string)
    field(:type, :string, default: "code")
    field(:assignee, :string)
    field(:status, :string, default: "todo")
    field(:priority, :integer, default: 0)
    field(:attempts, :integer, default: 0)
    field(:depends_on, {:array, :string}, default: [])
    field(:created_by, :string, default: "svarm")
    field(:created_at, :integer)
    field(:tenant, :string)
    field(:wait_reason, :string)
    field(:pending_question, :map)
    field(:follow_up, :string)
    field(:board_id, :string, default: "default")
    field(:external_task_id, :string)
    field(:workspace_locator, :string)
  end

  @doc """
  Changeset for creating/updating tasks from external attribute maps.

  `board_id` defaults to `"default"`. A missing `external_task_id` is copied
  from `id` so existing inserts keep a unique `(board_id, external_task_id)`.
  """
  def changeset(task, attrs) do
    task
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :title,
      :body,
      :type,
      :assignee,
      :status,
      :priority,
      :attempts,
      :depends_on,
      :created_by,
      :created_at,
      :tenant,
      :wait_reason,
      :pending_question,
      :follow_up,
      :board_id,
      :external_task_id,
      :workspace_locator
    ])
    |> copy_external_task_id()
    |> Ecto.Changeset.validate_required([:id, :title, :board_id, :external_task_id])
    |> Ecto.Changeset.unique_constraint([:board_id, :external_task_id],
      name: :tasks_board_id_external_task_id_index
    )
  end

  defp copy_external_task_id(changeset) do
    board_id = Ecto.Changeset.get_field(changeset, :board_id)

    changeset =
      if is_binary(board_id) and board_id != "" do
        changeset
      else
        Ecto.Changeset.put_change(changeset, :board_id, "default")
      end

    case Ecto.Changeset.get_field(changeset, :external_task_id) do
      id when is_binary(id) and id != "" ->
        changeset

      _ ->
        Ecto.Changeset.put_change(
          changeset,
          :external_task_id,
          Ecto.Changeset.get_field(changeset, :id)
        )
    end
  end
end
