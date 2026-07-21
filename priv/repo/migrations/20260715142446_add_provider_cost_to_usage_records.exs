defmodule Svarm.Repo.Migrations.AddProviderCostToUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add :provider_cost_usd, :float
    end
  end
end
