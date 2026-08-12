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

  # List fields merged only when present as a list in Settings (replace, not append).
  # skills → path strings; tools → PATH executable names (same trim/drop rules).
  @agent_list_fields %{"skills" => :skills, "tools" => :tools}

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
    existing
    |> merge_agent_string_fields(ov)
    |> merge_agent_list_fields(ov)
    |> merge_agent_tools_mode(ov)
  end

  defp merge_agent_string_fields(existing, ov) do
    Enum.reduce(@agent_field_map, existing, fn {str_key, atom_key}, acc ->
      case ov[str_key] do
        val when is_binary(val) and val != "" -> Map.put(acc, atom_key, val)
        _ -> acc
      end
    end)
  end

  defp merge_agent_list_fields(existing, ov) do
    Enum.reduce(@agent_list_fields, existing, fn {str_key, atom_key}, acc ->
      case ov[str_key] do
        list when is_list(list) -> Map.put(acc, atom_key, normalize_string_list(list))
        _ -> acc
      end
    end)
  end

  defp merge_agent_tools_mode(existing, ov) do
    # nil is an atom in Elixir — only apply when the key is present with a real value.
    case Map.fetch(ov, "tools_mode") do
      {:ok, mode} when is_binary(mode) ->
        Map.put(existing, :tools_mode, Svarm.Toolchain.normalize_mode(mode))

      {:ok, mode} when is_atom(mode) and not is_nil(mode) ->
        Map.put(existing, :tools_mode, Svarm.Toolchain.normalize_mode(mode))

      _ ->
        existing
    end
  end

  # Same rules as Runner.Cli.normalize_skills/1 and Toolchain.normalize_tools/1 —
  # keep Settings free of runner deps for the common trim/drop path.
  defp normalize_string_list(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val) when is_binary(val), do: Map.put(map, key, val)
  defp maybe_put(map, _key, _), do: map

  # Prefer atom-derived keys when both atom and string forms exist for the same name.
  defp stringify(map) when is_map(map) do
    strings =
      Enum.reduce(map, %{}, fn
        {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
        {_k, _v}, acc -> acc
      end)

    Enum.reduce(map, strings, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {_k, _v}, acc -> acc
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
