defmodule Svarm.Settings.Catalog.Schema.Revision do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:revision, :integer, autogenerate: false}
  schema "catalog_revisions" do
    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule Svarm.Settings.Catalog.Schema.Provider do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "catalog_provider_profiles" do
    field(:revision, :integer, primary_key: true)
    field(:id, :string, primary_key: true)
    field(:name, :string)
    field(:kind, :string)
    field(:endpoint, :string)
    field(:credential_id, :string)
    field(:default_model, :string)
  end
end

defmodule Svarm.Settings.Catalog.Schema.Harness do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "catalog_harness_profiles" do
    field(:revision, :integer, primary_key: true)
    field(:id, :string, primary_key: true)
    field(:name, :string)
    field(:adapter, :string)
    field(:provider_id, :string)
    field(:command, {:array, :string}, default: [])
    field(:env, :map, default: %{})
    field(:default_toolchain_id, :string)
  end
end

defmodule Svarm.Settings.Catalog.Schema.Toolchain do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "catalog_toolchain_profiles" do
    field(:revision, :integer, primary_key: true)
    field(:id, :string, primary_key: true)
    field(:name, :string)
    field(:source, :map)
  end
end

defmodule Svarm.Settings.Catalog.Schema.Board do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "catalog_boards" do
    field(:revision, :integer, primary_key: true)
    field(:id, :string, primary_key: true)
    field(:name, :string)
    field(:tracker, :map, default: %{})
    field(:remote, :map, default: %{})
    field(:enabled, :boolean, default: false)
    field(:max_concurrent, :integer)
    field(:verification, :map)
    field(:first_run_at, :utc_datetime)
  end
end

defmodule Svarm.Settings.Catalog.Schema.Binding do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "catalog_board_bindings" do
    field(:revision, :integer, primary_key: true)
    field(:board_id, :string, primary_key: true)
    field(:harness_id, :string)
    field(:model_override, :string)
    field(:credential_id, :string)
    field(:toolchain_id, :string)
  end
end
