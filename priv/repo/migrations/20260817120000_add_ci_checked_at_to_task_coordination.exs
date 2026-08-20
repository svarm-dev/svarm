defmodule Svarm.Repo.Migrations.AddCiCheckedAtToTaskCoordination do
  use Ecto.Migration

  def change do
    alter table(:task_coordination) do
      add(:ci_checked_at, :utc_datetime)
    end
  end
end
