defmodule Svarm.Settings.Resolve do
  @moduledoc """
  Settings → file/env fallback chain for adapters.

  Empty Settings leaves today's env/file behaviour unchanged.
  """

  alias Svarm.Settings

  @agent_field_map %{
    "provider" => :provider,
    "model" => :model,
    "adapter" => :adapter,
    "role" => :role,
    "name" => :display_name
  }

  @doc """
  OpenRouter API key: Settings secret first, then `OPENROUTER_API_KEY` (or
  `auth_env` from providers.toml).
  """
  def openrouter_api_key do
    case Settings.get_secret("provider.openrouter", "api_key") do
      key when is_binary(key) and key != "" -> key
      _ -> System.get_env(openrouter_auth_env())
    end
  end

  @doc """
  Merge Settings tracker fields onto a workflow tracker config map.
  Settings values win when present and non-blank.
  """
  def tracker_overlay(base) when is_map(base) do
    case Settings.get_raw("tracker") do
      {:ok, data} when map_size(data) > 0 -> merge_tracker(base, stringify(data))
      _ -> base
    end
  end

  def tracker_overlay(_), do: %{}

  @doc """
  Deep-merge Settings agent overrides onto file-loaded agents.
  Only known agent names (already in the file map) are updated.
  """
  def merge_agents(agents) when is_map(agents) do
    case Settings.get_section("agents") do
      {:ok, overrides} when is_map(overrides) -> apply_agent_overrides(agents, overrides)
      _ -> agents
    end
  end

  def merge_agents(other), do: other

  defp apply_agent_overrides(agents, overrides) do
    Enum.reduce(overrides, agents, fn {name, ov}, acc ->
      name = to_string(name)

      with true <- is_map(ov),
           {:ok, existing} <- Map.fetch(acc, name) do
        Map.put(acc, name, merge_agent_fields(existing, stringify(ov)))
      else
        _ -> acc
      end
    end)
  end

  defp merge_tracker(base, data) do
    base
    |> Map.put(:kind, parse_kind(data["kind"], base[:kind]))
    |> Map.put(:auth, parse_auth(data["auth"], base[:auth]))
    |> maybe_put(:owner, data["owner"])
    |> maybe_put(:repo, data["repo"])
    |> maybe_put_labels(data["required_labels"], base[:required_labels])
    |> maybe_put(:api_key, tracker_api_key(base[:api_key]))
  end

  defp parse_kind("github", _), do: :github
  defp parse_kind("local", _), do: :local
  defp parse_kind(:github, _), do: :github
  defp parse_kind(:local, _), do: :local
  defp parse_kind(_, fallback), do: fallback || :local

  defp parse_auth("app", _), do: :app
  defp parse_auth(:app, _), do: :app
  defp parse_auth("token", _), do: :token
  defp parse_auth(:token, _), do: :token
  defp parse_auth(_, fallback), do: fallback || :token

  defp tracker_api_key(fallback) do
    case Settings.get_secret("tracker", "api_key") do
      key when is_binary(key) and key != "" -> key
      _ -> fallback
    end
  end

  defp maybe_put_labels(map, list, _fallback) when is_list(list) do
    Map.put(map, :required_labels, Enum.map(list, &to_string/1))
  end

  defp maybe_put_labels(map, _list, fallback) when not is_nil(fallback) do
    Map.put(map, :required_labels, fallback)
  end

  defp maybe_put_labels(map, _, _), do: map

  defp merge_agent_fields(existing, ov) do
    Enum.reduce(@agent_field_map, existing, fn {str_key, atom_key}, acc ->
      case ov[str_key] do
        val when is_binary(val) and val != "" -> Map.put(acc, atom_key, val)
        _ -> acc
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val) when is_binary(val), do: Map.put(map, key, val)
  defp maybe_put(map, _key, _), do: map

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

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
