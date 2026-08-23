defmodule Svarm.Repo.Migrations.AddAttemptsToTaskCoordination do
  use Ecto.Migration

  def change do
    alter table(:task_coordination) do
      add(:attempts, :integer, null: false, default: 0)
    end
  end
end
