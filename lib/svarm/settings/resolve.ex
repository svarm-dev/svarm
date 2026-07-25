defmodule Svarm.Settings.Resolve do
  @moduledoc """
  Settings → file/env fallback chain for adapters.

  Empty Settings leaves today's env/file behaviour unchanged.
  """

  alias Svarm.Settings

  @agent_override_keys ~w(provider model adapter name role)

  @doc """
  OpenRouter API key: Settings secret first, then `OPENROUTER_API_KEY` (or
  `auth_env` from providers.toml).
  """
  def openrouter_api_key do
    case Settings.get_secret("provider.openrouter", "api_key") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        System.get_env(openrouter_auth_env())
    end
  end

  @doc """
  Merge Settings tracker fields onto a workflow tracker config map.
  Settings values win when present and non-blank.
  """
  def tracker_overlay(base) when is_map(base) do
    case Settings.get_raw("tracker") do
      {:ok, data} when map_size(data) > 0 ->
        merge_tracker(base, data)

      _ ->
        base
    end
  end

  def tracker_overlay(_), do: %{}

  @doc """
  Deep-merge Settings agent overrides onto file-loaded agents.
  Only known agent names (already in the file map) are updated.
  """
  def merge_agents(agents) when is_map(agents) do
    case Settings.get_section("agents") do
      {:ok, overrides} when is_map(overrides) ->
        Enum.reduce(overrides, agents, fn {name, ov}, acc ->
          name = to_string(name)

          case Map.fetch(acc, name) do
            {:ok, existing} when is_map(ov) ->
              Map.put(acc, name, merge_agent_fields(existing, ov))

            _ ->
              acc
          end
        end)

      _ ->
        agents
    end
  end

  def merge_agents(other), do: other

  defp merge_tracker(base, data) do
    kind =
      case data["kind"] || data[:kind] do
        "github" -> :github
        "local" -> :local
        :github -> :github
        :local -> :local
        _ -> base[:kind] || :local
      end

    auth =
      case data["auth"] || data[:auth] do
        "app" -> :app
        :app -> :app
        "token" -> :token
        :token -> :token
        _ -> base[:auth] || :token
      end

    labels =
      case data["required_labels"] || data[:required_labels] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> base[:required_labels]
      end

    api_key =
      case Settings.get_secret("tracker", "api_key") do
        key when is_binary(key) and key != "" -> key
        _ -> base[:api_key]
      end

    base
    |> Map.put(:kind, kind)
    |> maybe_put(:owner, data["owner"] || data[:owner])
    |> maybe_put(:repo, data["repo"] || data[:repo])
    |> Map.put(:auth, auth)
    |> then(fn m -> if labels, do: Map.put(m, :required_labels, labels), else: m end)
    |> then(fn m -> if api_key, do: Map.put(m, :api_key, api_key), else: m end)
  end

  defp merge_agent_fields(existing, ov) do
    Enum.reduce(@agent_override_keys, existing, fn key, acc ->
      val = ov[key] || ov[known_atom(key)]

      if is_binary(val) and val != "" do
        case key do
          "name" -> Map.put(acc, :display_name, val)
          "provider" -> Map.put(acc, :provider, val)
          "model" -> Map.put(acc, :model, val)
          "adapter" -> Map.put(acc, :adapter, val)
          "role" -> Map.put(acc, :role, val)
          _ -> acc
        end
      else
        acc
      end
    end)
  end

  defp known_atom("provider"), do: :provider
  defp known_atom("model"), do: :model
  defp known_atom("adapter"), do: :adapter
  defp known_atom("name"), do: :name
  defp known_atom("role"), do: :role
  defp known_atom(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val) when is_binary(val), do: Map.put(map, key, val)

  defp openrouter_auth_env do
    path = Path.join(:code.priv_dir(:svarm), "providers.toml")

    with {:ok, contents} <- File.read(path),
         {:ok, map} <- Toml.decode(contents),
         env when is_binary(env) and env != "" <-
           get_in(map, ["provider", "openrouter", "auth_env"]) do
      env
    else
      _ -> "OPENROUTER_API_KEY"
    end
  end
end
