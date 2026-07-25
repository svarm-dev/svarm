defmodule Svarm.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :section, :string, null: false
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:section])
  end
end
