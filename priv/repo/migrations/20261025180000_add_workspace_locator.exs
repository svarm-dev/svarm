defmodule Svarm.Repo.Migrations.AddWorkspaceLocator do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add(:workspace_locator, :string)
    end
  end
end
