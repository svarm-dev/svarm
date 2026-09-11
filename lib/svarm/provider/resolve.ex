defmodule Svarm.Provider.Resolve do
  @moduledoc """
  Single provider-id → `{adapter_module, config}` path for in-app LLM calls.

  `priv/providers.toml` is the advertised-provider source of truth. Kind →
  module lives **only** here. Decompose, Settings, and Orchestrator must not
  match on `== Provider.OpenRouter` to pick an adapter.
  """

  alias Svarm.{Settings, Workflow}
  alias Svarm.Provider.{OpenAICompat, OpenRouter}

  @config_file Path.join(:code.priv_dir(:svarm), "providers.toml")

  # Adapter name from toml → module. Register new HTTP adapters here.
  @adapters %{
    "openrouter" => OpenRouter,
    "openai_compat" => OpenAICompat
  }

  @default_id "openrouter"

  @doc """
  Live (non-stub) provider rows from `providers.toml`.

  Each map has `:id`, `:base_url`, `:auth_env`, `:adapter`, `:default_model`.
  """
  def advertised do
    provider_table()
    |> Enum.map(fn {id, row} -> entry_from_row(id, row) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Advertised row for `id`, or `nil`."
  def entry(id) when is_binary(id) do
    case Map.fetch(provider_table(), id) do
      {:ok, row} -> entry_from_row(id, row)
      :error -> nil
    end
  end

  def entry(_), do: nil

  @doc """
  Resolve a provider id to `{module, config}`.

  When `:provider` is omitted or blank, uses Settings default-agent provider,
  then WORKFLOW `agent.provider` / `provider`, then OpenRouter. An explicit
  unknown id fails closed (`{:error, :unknown_provider}`) — no silent swap.
  """
  def adapter_and_config(opts \\ []) when is_list(opts) do
    opts
    |> requested_id()
    |> resolve_id()
  end

  @doc "Same as `adapter_and_config/1` for a known id string."
  def resolve(id) when is_binary(id), do: resolve_id(id)

  @doc "Adapter module for a toml `adapter` name. Unknown names return nil."
  def adapter_module(name) when is_binary(name), do: Map.get(@adapters, name)
  def adapter_module(_), do: nil

  @doc "Env var name for `id` from toml, or nil when the id is not advertised."
  def auth_env(id) when is_binary(id) do
    case entry(id) do
      %{auth_env: env} -> env
      _ -> nil
    end
  end

  defp requested_id(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, id} when is_binary(id) and id != "" -> id
      {:ok, _} -> configured_id()
      :error -> configured_id()
    end
  end

  defp configured_id do
    settings_provider_id() || workflow_provider_id() || @default_id
  end

  defp settings_provider_id do
    case Settings.get_section("agents") do
      {:ok, agents} when is_map(agents) ->
        default = stringify(agents["default"] || agents[:default] || %{})
        present(default["provider"])

      _ ->
        nil
    end
  end

  defp workflow_provider_id do
    cfg =
      case Workflow.Store.get() do
        %{config: map} when is_map(map) -> map
        _ -> %{}
      end

    present(get_in(cfg, ["agent", "provider"])) || present(cfg["provider"])
  end

  defp resolve_id(id) do
    with %{} = config <- entry(id),
         mod when not is_nil(mod) <- adapter_module(config.adapter) do
      {:ok, {mod, config}}
    else
      _ -> {:error, :unknown_provider}
    end
  end

  defp provider_table do
    with {:ok, contents} <- File.read(@config_file),
         {:ok, map} <- Toml.decode(contents),
         table when is_map(table) <- Map.get(map, "provider") do
      table
    else
      _ -> %{}
    end
  end

  defp entry_from_row(id, row) when is_map(row) do
    %{
      id: id,
      base_url: row["base_url"],
      auth_env: row["auth_env"],
      adapter: row["adapter"] || default_adapter(id),
      default_model: row["default_model"]
    }
  end

  defp default_adapter("openrouter"), do: "openrouter"
  defp default_adapter(_), do: "openai_compat"

  defp present(val) when is_binary(val) and val != "", do: val
  defp present(_), do: nil

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify(_), do: %{}
end
