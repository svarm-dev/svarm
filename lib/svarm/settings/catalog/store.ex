defmodule Svarm.Settings.Catalog.Store do
  @moduledoc """
  Writes one catalog revision in a single SQLite transaction.

  Public reads are plain maps. Storage structs stay behind this module.
  """

  import Ecto.Query, only: [from: 2]

  alias Svarm.Repo
  alias Svarm.Settings.Catalog
  alias Svarm.Settings.Catalog.Schema.{Binding, Board, Harness, Provider, Revision, Toolchain}

  @doc "Highest committed revision, or nil when the catalog has not been imported."
  @spec latest_revision() :: pos_integer() | nil
  def latest_revision do
    Repo.one(from(r in Revision, select: max(r.revision)))
  end

  @doc "Load one committed revision. Returns `:error` when that revision does not exist."
  @spec get(pos_integer()) :: {:ok, map()} | :error
  def get(revision) when is_integer(revision) and revision > 0 do
    case Repo.get(Revision, revision) do
      nil -> :error
      row -> {:ok, load(row)}
    end
  end

  def get(_), do: :error

  @doc """
  Insert the next revision. A validation error rolls back every row from that attempt.

  `attrs` is a map with optional `providers`, `harnesses`, `toolchains`, `boards`,
  and `bindings` lists. Each list is a full snapshot, not a patch.
  """
  @spec insert_revision(map()) :: {:ok, map()} | {:error, Catalog.error()}
  def insert_revision(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      revision = next_revision()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Revision{revision: revision, inserted_at: now})

      with {:ok, parsed} <- Catalog.parse(attrs),
           :ok <- persist(revision, parsed),
           :ok <- Catalog.validate_references(parsed) do
        load(%Revision{revision: revision, inserted_at: now})
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize()
  end

  def insert_revision(_), do: {:error, :invalid_catalog}

  defp next_revision do
    (latest_revision() || 0) + 1
  end

  defp persist(revision, %Catalog{} = catalog) do
    Enum.each(catalog.providers, &Repo.insert!(provider_row(revision, &1)))
    Enum.each(catalog.harnesses, &Repo.insert!(harness_row(revision, &1)))
    Enum.each(catalog.toolchains, &Repo.insert!(toolchain_row(revision, &1)))
    Enum.each(catalog.boards, &Repo.insert!(board_row(revision, &1)))
    Enum.each(catalog.bindings, &Repo.insert!(binding_row(revision, &1)))
    :ok
  end

  defp load(%Revision{} = row) do
    parsed = %Catalog{
      providers: load_providers(row.revision),
      harnesses: load_harnesses(row.revision),
      toolchains: load_toolchains(row.revision),
      boards: load_boards(row.revision),
      bindings: load_bindings(row.revision)
    }

    Catalog.to_map(row.revision, row.inserted_at, parsed)
  end

  defp load_providers(revision) do
    from(r in Provider, where: r.revision == ^revision, order_by: r.id)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        id: row.id,
        name: row.name,
        kind: row.kind,
        endpoint: row.endpoint,
        credential_id: row.credential_id,
        default_model: row.default_model
      }
    end)
  end

  defp load_harnesses(revision) do
    from(r in Harness, where: r.revision == ^revision, order_by: r.id)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        id: row.id,
        name: row.name,
        adapter: row.adapter,
        provider_id: row.provider_id,
        command: row.command || [],
        env: row.env || %{},
        default_toolchain_id: row.default_toolchain_id
      }
    end)
  end

  defp load_toolchains(revision) do
    from(r in Toolchain, where: r.revision == ^revision, order_by: r.id)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{id: row.id, name: row.name, source: row.source}
    end)
  end

  defp load_boards(revision) do
    from(r in Board, where: r.revision == ^revision, order_by: r.id)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        id: row.id,
        name: row.name,
        tracker: row.tracker || %{},
        remote: row.remote || %{},
        enabled: row.enabled,
        max_concurrent: row.max_concurrent,
        verification: row.verification,
        first_run_at: row.first_run_at
      }
    end)
  end

  defp load_bindings(revision) do
    from(r in Binding, where: r.revision == ^revision, order_by: r.board_id)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        board_id: row.board_id,
        harness_id: row.harness_id,
        model_override: row.model_override,
        credential_id: row.credential_id,
        toolchain_id: row.toolchain_id
      }
    end)
  end

  defp provider_row(revision, provider) do
    %Provider{
      revision: revision,
      id: provider.id,
      name: provider.name,
      kind: provider.kind,
      endpoint: provider.endpoint,
      credential_id: provider.credential_id,
      default_model: provider.default_model
    }
  end

  defp harness_row(revision, harness) do
    %Harness{
      revision: revision,
      id: harness.id,
      name: harness.name,
      adapter: harness.adapter,
      provider_id: harness.provider_id,
      command: harness.command,
      env: harness.env,
      default_toolchain_id: harness.default_toolchain_id
    }
  end

  defp toolchain_row(revision, toolchain) do
    %Toolchain{
      revision: revision,
      id: toolchain.id,
      name: toolchain.name,
      source: toolchain.source
    }
  end

  defp board_row(revision, board) do
    %Board{
      revision: revision,
      id: board.id,
      name: board.name,
      tracker: board.tracker,
      remote: board.remote,
      enabled: board.enabled,
      max_concurrent: board.max_concurrent,
      verification: board.verification,
      first_run_at: board.first_run_at
    }
  end

  defp binding_row(revision, binding) do
    %Binding{
      revision: revision,
      board_id: binding.board_id,
      harness_id: binding.harness_id,
      model_override: binding.model_override,
      credential_id: binding.credential_id,
      toolchain_id: binding.toolchain_id
    }
  end

  defp normalize({:ok, map}), do: {:ok, map}
  defp normalize({:error, reason}), do: {:error, reason}
end
