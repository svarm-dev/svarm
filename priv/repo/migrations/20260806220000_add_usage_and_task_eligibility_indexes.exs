defmodule Svarm.Repo.Migrations.AddUsageAndTaskEligibilityIndexes do
  use Ecto.Migration

  def change do
    # Usage window totals / records_since filter on recorded_at
    create index(:usage_records, [:recorded_at])

    # Eligibility + list: filter by status, order by priority, created_at
    create index(:tasks, [:status, :priority, :created_at])
  end
end
