defmodule Svarm.Repo.Migrations.AddBoardIdentityAndCatalog do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add(:board_id, :string, null: false, default: "default")
      add(:external_task_id, :string)
    end

    flush()

    execute("UPDATE tasks SET external_task_id = id WHERE external_task_id IS NULL")

    create(unique_index(:tasks, [:board_id, :external_task_id]))

    alter table(:run_logs) do
      add(:board_id, :string, null: false, default: "default")
    end

    alter table(:usage_records) do
      add(:board_id, :string, null: false, default: "default")
    end

    alter table(:task_coordination) do
      add(:board_id, :string, null: false, default: "default")
    end

    create table(:catalog_revisions, primary_key: false) do
      add(:revision, :integer, primary_key: true, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:catalog_provider_profiles, primary_key: false) do
      add(:revision, :integer, null: false)
      add(:id, :string, null: false)
      add(:name, :string, null: false)
      add(:kind, :string, null: false)
      add(:endpoint, :string)
      add(:credential_id, :string)
      add(:default_model, :string, null: false)
    end

    create(unique_index(:catalog_provider_profiles, [:revision, :id]))

    create table(:catalog_harness_profiles, primary_key: false) do
      add(:revision, :integer, null: false)
      add(:id, :string, null: false)
      add(:name, :string, null: false)
      add(:adapter, :string, null: false)
      add(:provider_id, :string, null: false)
      add(:command, {:array, :string}, null: false, default: [])
      add(:env, :map, null: false, default: %{})
      add(:default_toolchain_id, :string)
    end

    create(unique_index(:catalog_harness_profiles, [:revision, :id]))

    create table(:catalog_toolchain_profiles, primary_key: false) do
      add(:revision, :integer, null: false)
      add(:id, :string, null: false)
      add(:name, :string, null: false)
      add(:source, :map, null: false)
    end

    create(unique_index(:catalog_toolchain_profiles, [:revision, :id]))

    create table(:catalog_boards, primary_key: false) do
      add(:revision, :integer, null: false)
      add(:id, :string, null: false)
      add(:name, :string, null: false)
      add(:tracker, :map, null: false, default: %{})
      add(:remote, :map, null: false, default: %{})
      add(:enabled, :boolean, null: false, default: false)
      add(:max_concurrent, :integer)
      add(:verification, :map)
      add(:first_run_at, :utc_datetime)
    end

    create(unique_index(:catalog_boards, [:revision, :id]))

    create table(:catalog_board_bindings, primary_key: false) do
      add(:revision, :integer, null: false)
      add(:board_id, :string, null: false)
      add(:harness_id, :string, null: false)
      add(:model_override, :string)
      add(:credential_id, :string)
      add(:toolchain_id, :string)
    end

    create(unique_index(:catalog_board_bindings, [:revision, :board_id]))
  end

  def down do
    drop(table(:catalog_board_bindings))
    drop(table(:catalog_boards))
    drop(table(:catalog_toolchain_profiles))
    drop(table(:catalog_harness_profiles))
    drop(table(:catalog_provider_profiles))
    drop(table(:catalog_revisions))

    drop_if_exists(unique_index(:tasks, [:board_id, :external_task_id]))

    alter table(:tasks) do
      remove(:external_task_id)
      remove(:board_id)
    end

    alter table(:run_logs) do
      remove(:board_id)
    end

    alter table(:usage_records) do
      remove(:board_id)
    end

    alter table(:task_coordination) do
      remove(:board_id)
    end
  end
end
