defmodule Svarm.Repo.Migrations.CreateTaskCoordination do
  use Ecto.Migration

  def change do
    create table(:task_coordination, primary_key: false) do
      add :task_id, :string, primary_key: true
      add :pr_url, :string
      add :pr_owner, :string
      add :pr_repo, :string
      add :pr_number, :integer
      add :ci_resume_count, :integer, null: false, default: 0
      add :ci_last_head_sha, :string
      add :ci_last_conclusion, :string
      add :ci_circuit_open, :boolean, null: false, default: false
      add :ci_context_summary, :text

      timestamps(type: :utc_datetime)
    end

    create index(:task_coordination, [:pr_owner, :pr_repo, :pr_number])
  end
end
