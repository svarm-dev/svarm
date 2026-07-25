defmodule Svarm.Settings.Store do
  @moduledoc """
  Ecto-backed settings sections. One row per section string; `data` is a map.

  Returns plain maps — never Ecto structs — to callers.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Svarm.Repo

  schema "settings" do
    field(:section, :string)
    field(:data, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc "Fetch section data. Returns `{:ok, map}` or `:error`."
  def get(section) when is_binary(section) do
    case Repo.get_by(__MODULE__, section: section) do
      nil -> :error
      row -> {:ok, row.data || %{}}
    end
  end

  @doc "Upsert section data. Returns `{:ok, map}` or `{:error, changeset}`."
  def put(section, data) when is_binary(section) and is_map(data) do
    row = Repo.get_by(__MODULE__, section: section) || %__MODULE__{section: section}

    row
    |> change(%{data: data})
    |> validate_required([:section, :data])
    |> unique_constraint(:section)
    |> Repo.insert_or_update()
    |> case do
      {:ok, saved} -> {:ok, saved.data || %{}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Delete a section. Returns `:ok`."
  def delete(section) when is_binary(section) do
    from(s in __MODULE__, where: s.section == ^section) |> Repo.delete_all()
    :ok
  end
end
