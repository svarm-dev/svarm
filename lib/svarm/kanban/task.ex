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
  end

  @doc """
  Changeset for creating/updating tasks from external attribute maps.
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
      :pending_question
    ])
    |> Ecto.Changeset.validate_required([:id, :title])
  end
end
