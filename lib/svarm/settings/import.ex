defmodule Svarm.Settings.Import do
  @moduledoc """
  One-shot copy of the current file, env, and Settings overlay into catalog revision 1.

  Credential plaintext stays in the encrypted settings store. Catalog rows keep
  credential ids, or nil when the secret lives only in the environment.
  """

  alias Svarm.KanbanBridge
  alias Svarm.Provider.Resolve, as: ProviderResolve
  alias Svarm.Settings
  alias Svarm.Settings.Catalog.Store, as: CatalogStore
  alias Svarm.Tracker.Resolve, as: TrackerResolve
  alias Svarm.Workflow
  alias Svarm.Workflow.Config, as: WorkflowConfig

  @tracker_fields ~w(
    kind auth owner repo base_url workspace project
    active_states terminal_states required_labels agent_assignees ignored_assignees
    app_id installation_id private_key_path column_slugs status_labels reverse_labels
  )

  @secret_fields ~w(api_key token secret password private_key authorization access_token bearer)

  @doc """
  Build and insert the first catalog revision.

  Callers must check `Catalog.Store.latest_revision/0` first when a repeat
  must not read files. This function still refuses to append revision 2.
  """
  @spec run() :: {:ok, map() | :already_imported} | {:error, term()}
  def run do
    case CatalogStore.insert_first_revision(snapshot()) do
      {:ok, %{} = saved} ->
        KanbanBridge.stamp_legacy_locators()
        {:ok, saved}

      other ->
        other
    end
  end

  defp snapshot do
    agents = Svarm.AgentRunner.load_agents()
    {toolchains, toolchain_id} = toolchains(agents)
    providers = providers(agents)
    harnesses = harnesses(agents, toolchain_id)

    %{
      "providers" => providers,
      "harnesses" => harnesses,
      "toolchains" => toolchains,
      "boards" => [board()],
      "bindings" => bindings(harnesses, providers)
    }
  end

  defp board do
    %{
      "id" => "default",
      "name" => "Default",
      "tracker" => public_tracker(),
      "remote" => public_remote(),
      "enabled" => true
    }
  end

  defp public_tracker do
    effective = TrackerResolve.active_config()
    encoded = encode_tracker(effective)
    kind = encoded["kind"]

    encoded
    |> maybe_put("credential_id", tracker_credential_id())
    |> maybe_put("credential_env", credential_env(kind))
  end

  defp encode_tracker(config) when is_map(config) do
    config
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@tracker_fields)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case encode_value(value) do
        {:ok, encoded} ->
          if secret_value?(encoded), do: acc, else: Map.put(acc, key, encoded)

        :drop ->
          acc
      end
    end)
  end

  defp encode_value(value) when is_binary(value) and value != "", do: {:ok, value}

  defp encode_value(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp encode_value(list) when is_list(list) do
    encoded =
      Enum.flat_map(list, fn
        item when is_binary(item) and item != "" -> [item]
        item when is_atom(item) and not is_nil(item) -> [Atom.to_string(item)]
        _ -> []
      end)

    {:ok, encoded}
  end

  defp encode_value(map) when is_map(map) and not is_struct(map) do
    pairs =
      Enum.reduce(map, %{}, fn {key, value}, acc ->
        case encode_value(value) do
          {:ok, encoded} when is_binary(encoded) -> Map.put(acc, to_string(key), encoded)
          _ -> acc
        end
      end)

    {:ok, pairs}
  end

  defp encode_value(_), do: :drop

  defp tracker_credential_id do
    case Settings.get_secret("tracker", "api_key") do
      key when is_binary(key) and key != "" -> "tracker"
      _ -> nil
    end
  end

  defp credential_env("github"), do: env_name(raw_tracker_api_key(), "GITHUB_TOKEN")
  defp credential_env("kaneo"), do: env_name(raw_tracker_api_key(), "KANEO_API_KEY")
  defp credential_env(_), do: env_name(raw_tracker_api_key(), nil)

  defp env_name("$" <> var, fallback), do: env_name(var, fallback)

  defp env_name(name, _fallback) when is_binary(name) do
    name = String.trim(name)
    if Regex.match?(~r/^[A-Z][A-Z0-9_]{0,80}$/, name), do: name, else: nil
  end

  defp env_name(_, fallback), do: fallback

  defp raw_tracker_api_key do
    case Workflow.Store.get() do
      %{config: %{"tracker" => tracker}} when is_map(tracker) -> tracker["api_key"]
      _ -> nil
    end
  end

  defp public_remote do
    cfg = workflow_config()

    %{}
    |> maybe_put("url", scrub_url(cfg[:workspace_git_remote]))
    |> maybe_put("repo", plain_string(cfg[:workspace_git_repo]))
  end

  defp workflow_config do
    case Workflow.Store.get() do
      %Workflow{} = wf -> WorkflowConfig.from(wf)
      _ -> %{}
    end
  end

  defp scrub_url(url) when is_binary(url) and url != "" do
    cleaned =
      url
      |> URI.parse()
      |> Map.put(:userinfo, nil)
      |> URI.to_string()

    if secret_value?(cleaned), do: nil, else: cleaned
  end

  defp scrub_url(_), do: nil

  defp providers(agents) do
    referenced =
      agents
      |> Map.values()
      |> Enum.map(&provider_id/1)

    ready =
      ProviderResolve.advertised()
      |> Enum.filter(&provider_ready?/1)
      |> Enum.map(& &1.id)

    (referenced ++ ready)
    |> Enum.uniq()
    |> Enum.map(&provider_row(&1, agents))
  end

  defp provider_ready?(%{id: id, auth_env: env}) do
    provider_secret?(id) or env_present?(env)
  end

  defp provider_secret?(id) do
    match?(
      key when is_binary(key) and key != "",
      Settings.get_secret("provider.#{id}", "api_key")
    )
  end

  defp env_present?(env) when is_binary(env) and env != "" do
    match?(value when is_binary(value) and value != "", System.get_env(env))
  end

  defp env_present?(_), do: false

  defp provider_row(id, agents) do
    entry = ProviderResolve.entry(id)

    %{
      "id" => id,
      "name" => provider_name(id),
      "kind" => provider_kind(entry),
      "endpoint" => entry && plain_string(entry.base_url),
      "credential_id" => if(provider_secret?(id), do: "provider.#{id}"),
      "default_model" => provider_model(id, entry, agents)
    }
    |> drop_nil()
  end

  defp provider_name(id) do
    case ProviderResolve.label(id) do
      name when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  defp provider_kind(%{adapter: adapter}) when is_binary(adapter) and adapter != "", do: adapter
  defp provider_kind(_), do: "provider"

  defp provider_model(id, entry, agents) do
    from_agent =
      Enum.find_value(agents, fn {_name, agent} ->
        if provider_id(agent) == id, do: plain_string(agent[:model])
      end)

    from_agent || (entry && plain_string(entry.default_model)) || "unspecified"
  end

  defp harnesses(agents, toolchain_id) when is_map(agents) do
    agents
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.map(fn {name, agent} -> harness_row(to_string(name), agent, toolchain_id) end)
  end

  defp harness_row(name, agent, toolchain_id) do
    tools = agent[:tools] || []

    %{
      "id" => name,
      "name" => plain_string(agent[:display_name]) || name,
      "adapter" => catalog_adapter(agent[:adapter]),
      "provider_id" => provider_id(agent),
      "command" => command(agent),
      "env" => scrub_env(agent[:env] || %{}),
      "default_toolchain_id" => if(tools != [] and toolchain_id, do: toolchain_id)
    }
    |> drop_nil()
  end

  defp catalog_adapter("pi_rpc"), do: "pi_rpc"
  defp catalog_adapter(:pi_rpc), do: "pi_rpc"
  defp catalog_adapter(_), do: "cli"

  defp provider_id(%{provider: id}) when is_binary(id) and id != "", do: id
  defp provider_id(_), do: "openrouter"

  defp command(agent) do
    [agent[:command] | agent[:args] || []]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or secret_value?(&1)))
  end

  defp scrub_env(env) when is_map(env) do
    Enum.reduce(env, %{}, fn {key, value}, acc ->
      key = to_string(key)

      cond do
        secret_field?(key) -> acc
        not is_binary(value) -> acc
        secret_value?(value) -> acc
        true -> Map.put(acc, key, value)
      end
    end)
  end

  defp scrub_env(_), do: %{}

  defp toolchains(agents) when is_map(agents) do
    requirements =
      agents
      |> Map.values()
      |> Enum.flat_map(&(&1[:tools] || []))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if requirements == [] do
      {[], nil}
    else
      {[
         %{
           "id" => "path",
           "name" => "PATH",
           "source" => %{"type" => "path", "requirements" => requirements}
         }
       ], "path"}
    end
  end

  defp toolchains(_), do: {[], nil}

  defp bindings([], _providers), do: []

  defp bindings(harnesses, providers) do
    harness = Enum.find(harnesses, &(&1["id"] == "default")) || hd(harnesses)
    credential_id = provider_credential(providers, harness["provider_id"])

    [
      %{
        "board_id" => "default",
        "harness_id" => harness["id"],
        "credential_id" => credential_id,
        "toolchain_id" => harness["default_toolchain_id"]
      }
      |> drop_nil()
    ]
  end

  defp provider_credential(providers, id) do
    Enum.find_value(providers, fn provider ->
      if provider["id"] == id, do: provider["credential_id"]
    end)
  end

  defp secret_field?(key) do
    down = String.downcase(to_string(key))

    down in @secret_fields or String.ends_with?(down, "_token") or
      String.ends_with?(down, "_secret") or String.ends_with?(down, "_password") or
      String.ends_with?(down, "_api_key") or String.ends_with?(down, "_private_key")
  end

  defp secret_value?(value) when is_binary(value) do
    Svarm.Redact.text(value) != value or String.contains?(value, "PRIVATE KEY-----")
  end

  defp secret_value?(list) when is_list(list), do: Enum.any?(list, &secret_value?/1)

  defp secret_value?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> secret_field?(key) or secret_value?(value) end)
  end

  defp secret_value?(_), do: false

  defp plain_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "" or secret_value?(trimmed), do: nil, else: trimmed
  end

  defp plain_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
