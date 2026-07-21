defmodule Svarm.Repo.Migrations.CreateUsageRecords do
  use Ecto.Migration

  def change do
    create table(:usage_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :run_id, :string, null: false
      add :task_id, :string, null: false
      add :tenant, :string
      add :source, :string, null: false
      add :provider, :string
      add :model_id, :string
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :estimated, :boolean, default: false
      add :recorded_at, :integer, null: false
    end

    create index(:usage_records, [:task_id])
    create index(:usage_records, [:tenant])
    create index(:usage_records, [:run_id])
    create index(:usage_records, [:source])
  end
end
