defmodule Svarm.Repo.Migrations.AddRunLogs do
  use Ecto.Migration

  def change do
    create table(:run_logs) do
      add :task_id, :string, null: false
      add :content, :text, null: false, default: ""

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:run_logs, [:task_id])
  end
end
