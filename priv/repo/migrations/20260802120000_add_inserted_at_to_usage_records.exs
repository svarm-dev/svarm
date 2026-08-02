defmodule Svarm.Repo.Migrations.AddInsertedAtToUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add :inserted_at, :utc_datetime_usec, null: true
    end

    create index(:usage_records, [:inserted_at])
  end
end
