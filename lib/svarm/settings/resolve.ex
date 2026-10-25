defmodule Svarm.Settings.Resolve do
  @moduledoc """
  Settings → file/env fallback chain for adapters.

  Empty Settings leaves today's env/file behaviour unchanged.
  """

  alias Svarm.Settings
  alias Svarm.Settings.Catalog.Store, as: CatalogStore

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
  def openrouter_api_key, do: provider_api_key("openrouter")

  @doc """
  Provider API key: Settings secret `provider.<id>` `api_key` if present,
  else `System.get_env(auth_env)` from the advertised toml row.
  """
  def provider_api_key(id) when is_binary(id) do
    case Settings.get_secret("provider.#{id}", "api_key") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case Svarm.Provider.Resolve.auth_env(id) do
          env when is_binary(env) and env != "" -> System.get_env(env)
          _ -> nil
        end
    end
  end

  @doc """
  Tracker config for the default board.

  No catalog revision merges Settings onto the workflow map. After import,
  the default board row wins, including over a later WORKFLOW.md kind change.
  Secrets are read from the settings store or the recorded env name, not from
  the catalog row.
  """
  def tracker_overlay(base) when is_map(base) do
    case catalog_tracker() do
      {:ok, config} -> config
      :error -> legacy_tracker_overlay(base)
    end
  end

  def tracker_overlay(_), do: %{}

  @doc """
  Runtime tracker config for one catalog board map.

  Same secret and kind rules as the default-board overlay. Does not choose
  an adapter module. Call `Svarm.Tracker.Resolve.adapter_and_config/1`.
  """
  def tracker_config(tracker) when is_map(tracker), do: runtime_tracker(tracker)
  def tracker_config(_), do: runtime_tracker(%{})

  defp legacy_tracker_overlay(base) do
    case Settings.get_raw("tracker") do
      {:ok, data} when map_size(data) > 0 -> merge_tracker(base, stringify(data))
      _ -> base
    end
  end

  defp catalog_tracker do
    with revision when is_integer(revision) <- CatalogStore.latest_revision(),
         {:ok, snapshot} <- CatalogStore.get(revision),
         %{} = board <- Enum.find(snapshot.boards, &(&1.id == "default")) do
      {:ok, runtime_tracker(board.tracker || %{})}
    else
      _ -> :error
    end
  end

  defp runtime_tracker(tracker) when is_map(tracker) do
    tracker = stringify(tracker)
    kind = parse_kind(tracker["kind"], :local)

    %{
      kind: kind,
      auth: parse_auth(tracker["auth"], :token)
    }
    |> copy_string(:owner, tracker)
    |> copy_string(:repo, tracker)
    |> copy_string(:base_url, tracker)
    |> copy_string(:workspace, tracker)
    |> copy_string(:project, tracker)
    |> copy_string(:app_id, tracker)
    |> copy_string(:installation_id, tracker)
    |> copy_string(:private_key_path, tracker)
    |> copy_list(:active_states, tracker)
    |> copy_list(:terminal_states, tracker)
    |> copy_list(:required_labels, tracker)
    |> copy_list(:agent_assignees, tracker)
    |> copy_list(:ignored_assignees, tracker)
    |> copy_string_map(:column_slugs, tracker)
    |> copy_string_map(:status_labels, tracker)
    |> copy_string_map(:reverse_labels, tracker)
    |> maybe_put(:api_key, catalog_api_key(tracker))
    |> maybe_put(:private_key, catalog_private_key(kind, tracker))
  end

  defp catalog_api_key(tracker) do
    case Settings.get_secret("tracker", "api_key") do
      key when is_binary(key) and key != "" -> key
      _ -> env_value(tracker["credential_env"])
    end
  end

  defp catalog_private_key(:github, %{"auth" => "app"}) do
    System.get_env("SVARM_GITHUB_APP_PRIVATE_KEY")
  end

  defp catalog_private_key(_, _), do: nil

  defp env_value(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]{0,80}$/, name), do: System.get_env(name), else: nil
  end

  defp env_value(_), do: nil

  defp copy_string(map, key, tracker) do
    maybe_put(map, key, tracker[Atom.to_string(key)])
  end

  defp copy_list(map, key, tracker) do
    case tracker[Atom.to_string(key)] do
      list when is_list(list) -> Map.put(map, key, Enum.map(list, &to_string/1))
      _ -> map
    end
  end

  defp copy_string_map(map, key, tracker) do
    case tracker[Atom.to_string(key)] do
      nested when is_map(nested) ->
        Map.put(map, key, Map.new(nested, fn {k, v} -> {to_string(k), to_string(v)} end))

      _ ->
        map
    end
  end

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
    |> Map.put(:kind, merge_kind(base[:kind], data["kind"]))
    |> Map.put(:auth, parse_auth(data["auth"], base[:auth]))
    |> maybe_put(:owner, data["owner"])
    |> maybe_put(:repo, data["repo"])
    |> maybe_put(:base_url, data["base_url"] || base[:base_url])
    |> maybe_put(:workspace, data["workspace"] || base[:workspace])
    |> maybe_put(:project, data["project"] || base[:project])
    |> maybe_put_labels(data["required_labels"], base[:required_labels])
    |> maybe_put(:api_key, tracker_api_key(base[:api_key]))
  end

  # A leftover GitHub/local settings row must not undo WORKFLOW `kind: kaneo`.
  # Switch away from Kaneo in WORKFLOW.md, not by an older settings kind.
  defp merge_kind(:kaneo, _settings_kind), do: :kaneo
  defp merge_kind(base_kind, settings_kind), do: parse_kind(settings_kind, base_kind)

  defp parse_kind("github", _), do: :github
  defp parse_kind("local", _), do: :local
  defp parse_kind("kaneo", _), do: :kaneo
  defp parse_kind(:github, _), do: :github
  defp parse_kind(:local, _), do: :local
  defp parse_kind(:kaneo, _), do: :kaneo
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
end
