defmodule Svarm.Repo.Migrations.AddFollowUpToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :follow_up, :string
    end
  end
end