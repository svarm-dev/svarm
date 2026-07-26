defmodule Svarm.Settings do
  @moduledoc """
  Public API for in-app configuration (single-tenant settings store).

  Secrets are encrypted at rest. Read APIs redact secrets (`api_key_set?`);
  adapters use `get_secret/2` for plaintext. Empty Settings falls back to
  file/env via `Svarm.Settings.Resolve`.
  """

  alias Svarm.Provider.OpenRouter
  alias Svarm.Settings.{Crypto, Resolve, Store}
  alias Svarm.Tracker

  @secret_fields %{
    "provider.openrouter" => ["api_key"],
    "tracker" => ["api_key"],
    "agents" => [],
    "meta" => []
  }

  ## Read

  @doc """
  Redacted section map for UI. Secret fields become `api_key_set?: boolean`
  (ciphertext never returned). Keys are atoms for known fields.
  """
  def get_section(section) when is_binary(section) do
    case Store.get(section) do
      {:ok, data} -> {:ok, redact(section, data)}
      :error -> :error
    end
  end

  @doc false
  def get_raw(section) when is_binary(section), do: Store.get(section)

  @doc "Plaintext secret for adapters only. Returns nil when unset/invalid."
  def get_secret(section, field) when is_binary(section) and is_binary(field) do
    with {:ok, data} <- Store.get(section),
         enc when is_binary(enc) and enc != "" <- data[field],
         {:ok, plain} <- Crypto.decrypt(enc) do
      plain
    else
      _ -> nil
    end
  end

  ## Write

  @doc """
  Upsert a section. Encrypts known secret fields. Blank secret values keep
  the previously stored ciphertext (so forms can omit re-entry).
  """
  def put_section(section, attrs) when is_binary(section) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    existing = store_map(section)
    data = prepare_for_store(section, attrs, existing)

    case Store.put(section, data) do
      {:ok, saved} -> {:ok, redact(section, saved)}
      {:error, _} = err -> err
    end
  end

  @doc "Save OpenRouter provider settings."
  def put_provider(attrs) when is_map(attrs), do: put_section("provider.openrouter", attrs)

  @doc "Save tracker settings (local or GitHub PAT)."
  def put_tracker(attrs) when is_map(attrs), do: put_section("tracker", attrs)

  @doc "Save default agent override (provider/model). Merged onto agents.toml."
  def put_default_agent(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    existing = store_map("agents")

    default =
      Map.merge(
        existing["default"] || %{},
        Map.take(attrs, ["provider", "model", "name", "role", "adapter"])
      )

    put_section("agents", Map.put(existing, "default", default))
  end

  ## Status + tests

  @doc """
  Aggregate readiness for `/setup` and `Board.instance_status/0`.
  """
  def status do
    provider_configured? = provider_configured?()
    tracker_ready? = tracker_ready?()
    agent_count = agent_count()
    default_model = default_model()

    %{
      provider_configured?: provider_configured?,
      provider_key_in_settings?: provider_key_in_settings?(),
      tracker_ready?: tracker_ready?,
      tracker_source: tracker_source(),
      agent_count: agent_count,
      default_model: default_model,
      default_model_set?: present?(default_model),
      setup_complete?: provider_configured? and tracker_ready? and agent_count > 0
    }
  end

  def provider_key_in_settings? do
    match?(key when is_binary(key) and key != "", get_secret("provider.openrouter", "api_key"))
  end

  def default_model do
    agents =
      case get_section("agents") do
        {:ok, m} -> m
        :error -> %{}
      end

    case get_in(agents, ["default", "model"]) do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        case get_section("provider.openrouter") do
          {:ok, p} ->
            p = stringify_keys(p)
            blank_to_nil(p["default_model"])

          :error ->
            nil
        end
    end
  end

  def provider_configured? do
    match?(key when is_binary(key) and key != "", Resolve.openrouter_api_key())
  end

  def tracker_ready? do
    tc = Resolve.tracker_overlay(workflow_tracker_config())

    case tc[:kind] || :local do
      :github -> present?(tc[:owner]) and present?(tc[:repo]) and present?(tc[:api_key])
      _ -> true
    end
  end

  def tracker_source do
    case Store.get("tracker") do
      {:ok, data} when map_size(data) > 0 -> "settings"
      _ -> "file"
    end
  end

  @doc """
  Smoke-test OpenRouter with current resolved key (Settings then env).

  Returns `{:ok, %{count: n, models: [id, ...]}}` (models capped for UI chips)
  or `{:error, reason}`.
  """
  def test_provider do
    case OpenRouter.list_models([]) do
      {:ok, models} when is_list(models) ->
        {:ok, %{count: length(models), models: Enum.take(models, 12)}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @doc """
  Smoke-test tracker using Settings overlay on workflow tracker config.
  Local always succeeds. GitHub lists eligible issues once.

  When `form_attrs` is provided, tests those values without writing Settings
  (blank PAT keeps the stored/env secret for the probe only).
  """
  def test_tracker do
    tc = Resolve.tracker_overlay(workflow_tracker_config())
    test_tracker_config(tc)
  end

  def test_tracker(form_attrs) when is_map(form_attrs) do
    form_attrs
    |> stringify_keys()
    |> tracker_config_from_form()
    |> test_tracker_config()
  end

  defp test_tracker_config(%{kind: :local}), do: {:ok, :local}
  defp test_tracker_config(%{kind: kind}) when kind != :github, do: {:ok, :local}

  defp test_tracker_config(tc) do
    if present?(tc[:owner]) and present?(tc[:repo]) and present?(tc[:api_key]) do
      case Tracker.GitHub.list_eligible(tc) do
        {:ok, issues} -> {:ok, length(issues)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    else
      {:error, "GitHub tracker needs owner, repo, and a PAT"}
    end
  end

  ## private

  defp store_map(section) do
    case Store.get(section) do
      {:ok, d} -> d
      :error -> %{}
    end
  end

  defp redact(section, data) do
    secrets = Map.get(@secret_fields, section, [])

    Enum.reduce(secrets, data, fn field, acc ->
      set? = match?(bin when is_binary(bin) and bin != "", acc[field])

      acc
      |> Map.delete(field)
      |> Map.put(:api_key_set?, set?)
    end)
    |> atomize_known_keys(section)
  end

  defp prepare_for_store(section, attrs, existing) do
    secrets = Map.get(@secret_fields, section, [])
    base = Map.merge(existing, Map.drop(attrs, secrets ++ ["api_key_set?"]))

    Enum.reduce(secrets, base, fn field, acc ->
      put_secret_field(acc, field, attrs[field], existing[field])
    end)
    |> Map.drop(["api_key_set?"])
  end

  defp put_secret_field(acc, field, val, _existing) when is_binary(val) and val != "" do
    Map.put(acc, field, Crypto.encrypt(val))
  end

  defp put_secret_field(acc, field, _val, enc) when is_binary(enc) and enc != "" do
    Map.put(acc, field, enc)
  end

  defp put_secret_field(acc, field, _val, _existing), do: Map.delete(acc, field)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp atomize_known_keys(data, "provider.openrouter") do
    data
    |> copy_string_key(:base_url)
    |> copy_string_key(:default_model)
    |> copy_string_key(:configured)
  end

  defp atomize_known_keys(data, "tracker") do
    data
    |> copy_string_key(:kind)
    |> copy_string_key(:owner)
    |> copy_string_key(:repo)
    |> copy_string_key(:auth)
    |> copy_string_key(:required_labels)
  end

  defp atomize_known_keys(data, _), do: data

  defp copy_string_key(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, v} -> Map.put(map, key, v)
      :error -> map
    end
  end

  defp agent_count do
    case Svarm.AgentRunner.load_agents() do
      agents when is_map(agents) -> map_size(agents)
      _ -> 0
    end
  end

  defp workflow_tracker_config do
    workflow = Svarm.Workflow.Store.get()
    cfg = if workflow, do: Svarm.Workflow.Config.from(workflow), else: %{}
    cfg[:tracker_config] || %{kind: :local}
  end

  defp tracker_config_from_form(form) do
    base = Resolve.tracker_overlay(workflow_tracker_config())
    kind = if form["tracker_kind"] == "github", do: :github, else: :local

    %{
      kind: kind,
      auth: :token,
      owner: blank_to_nil(form["tracker_owner"]) || base[:owner],
      repo: blank_to_nil(form["tracker_repo"]) || base[:repo],
      api_key: form_tracker_api_key(form, base),
      required_labels: form_tracker_labels(form, base)
    }
  end

  defp form_tracker_api_key(form, base) do
    case form["tracker_api_key"] do
      key when is_binary(key) and key != "" -> key
      _ -> base[:api_key] || get_secret("tracker", "api_key")
    end
  end

  defp form_tracker_labels(form, base) do
    case form["tracker_labels"] || form["required_labels"] do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      bin when is_binary(bin) and bin != "" -> parse_label_csv(bin)
      _ -> base[:required_labels] || []
    end
  end

  defp parse_label_csv(bin) do
    bin
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp format_error(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_error(reason) when is_map(reason) do
    reason
    |> stringify_keys()
    |> then(fn m -> m["message"] || m["reason"] end)
    |> case do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> "unexpected error — check credentials and try again"
    end
  end
end
