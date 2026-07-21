defmodule Svarm.Repo.Migrations.AddDependsOnToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :depends_on, :text, default: "[]"
    end
  end
end
