defmodule Svarm.SettingsTest do
  use ExUnit.Case, async: false

  alias Svarm.Settings
  alias Svarm.Settings.{Crypto, Resolve, Store}

  setup do
    cleanup = fn ->
      Store.delete("provider.openrouter")
      Store.delete("provider.opencode-go")
      Store.delete("provider.opencode")
      Store.delete("tracker")
      Store.delete("agents")
      Store.delete("meta")
    end

    cleanup.()
    on_exit(cleanup)
    :ok
  end

  test "crypto round-trip" do
    ct = Crypto.encrypt("secret-value")
    assert is_binary(ct)
    assert ct != "secret-value"
    assert {:ok, "secret-value"} = Crypto.decrypt(ct)
  end

  test "crypto wrong ciphertext fails" do
    assert :error = Crypto.decrypt("not-valid-ciphertext")
  end

  test "put_provider encrypts and redacts api key" do
    assert {:ok, section} =
             Settings.put_provider(%{
               "api_key" => "sk-test-123",
               "default_model" => "openrouter/free"
             })

    refute Map.has_key?(section, "api_key")
    assert section.api_key_set? == true

    assert section[:default_model] == "openrouter/free" or
             section["default_model"] == "openrouter/free"

    assert Settings.get_secret("provider.openrouter", "api_key") == "sk-test-123"
  end

  test "blank api_key on put keeps existing secret" do
    assert {:ok, _} = Settings.put_provider(%{"api_key" => "sk-keep"})
    assert {:ok, _} = Settings.put_provider(%{"api_key" => "", "default_model" => "m1"})
    assert Settings.get_secret("provider.openrouter", "api_key") == "sk-keep"
  end

  test "openrouter_api_key prefers Settings over env" do
    prev = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "from-env")

    on_exit(fn ->
      if prev,
        do: System.put_env("OPENROUTER_API_KEY", prev),
        else: System.delete_env("OPENROUTER_API_KEY")
    end)

    assert Resolve.openrouter_api_key() == "from-env"

    assert {:ok, _} = Settings.put_provider(%{"api_key" => "from-settings"})
    assert Resolve.openrouter_api_key() == "from-settings"
  end

  test "provider_api_key uses Settings secret then shared OPENCODE_API_KEY" do
    prev = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "from-env")

    on_exit(fn ->
      if prev,
        do: System.put_env("OPENCODE_API_KEY", prev),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    assert Resolve.provider_api_key("opencode-go") == "from-env"
    assert Resolve.provider_api_key("opencode") == "from-env"

    assert {:ok, section} =
             Settings.put_section("provider.opencode-go", %{"api_key" => "from-settings"})

    refute Map.has_key?(section, "api_key")
    assert section.api_key_set? == true
    assert Settings.get_secret("provider.opencode-go", "api_key") == "from-settings"
    assert Resolve.provider_api_key("opencode-go") == "from-settings"
  end

  test "tracker_overlay merges Settings onto base" do
    base = %{kind: :local, owner: nil, repo: nil}

    assert Resolve.tracker_overlay(base) == base

    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_test",
               "auth" => "token"
             })

    over = Resolve.tracker_overlay(base)
    assert over.kind == :github
    assert over.owner == "acme"
    assert over.repo == "widgets"
    assert over.api_key == "ghp_test"
  end

  test "merge_agents overrides known default only" do
    agents = %{
      "default" => %{command: "pi", model: "old", provider: "openrouter"},
      "demo" => %{command: "sh", model: "x"}
    }

    assert {:ok, _} =
             Settings.put_default_agent(%{"model" => "new-model", "provider" => "openrouter"})

    merged = Resolve.merge_agents(agents)
    assert merged["default"].model == "new-model"
    assert merged["demo"].model == "x"
  end

  test "merge_agents replaces skills list when Settings provides one" do
    agents = %{
      "default" => %{
        command: "pi",
        model: "m",
        provider: "openrouter",
        skills: ["packs/old"]
      },
      "demo" => %{command: "sh", skills: ["packs/demo"]}
    }

    assert {:ok, _} =
             Settings.put_section("agents", %{
               "default" => %{"skills" => [" packs/new ", "", "packs/shared"]}
             })

    merged = Resolve.merge_agents(agents)
    assert merged["default"].skills == ["packs/new", "packs/shared"]
    assert merged["demo"].skills == ["packs/demo"]
  end

  test "merge_agents leaves file skills when Settings omits skills" do
    agents = %{
      "default" => %{command: "pi", skills: ["packs/keep"]}
    }

    assert {:ok, _} =
             Settings.put_section("agents", %{"default" => %{"model" => "only-model"}})

    merged = Resolve.merge_agents(agents)
    assert merged["default"].skills == ["packs/keep"]
    assert merged["default"].model == "only-model"
  end

  test "merge_agents replaces tools list and tools_mode when Settings provides them" do
    agents = %{
      "default" => %{
        command: "pi",
        tools: ["mix"],
        tools_mode: :fail
      },
      "demo" => %{command: "sh", tools: ["node"], tools_mode: :warn}
    }

    assert {:ok, _} =
             Settings.put_section("agents", %{
               "default" => %{"tools" => [" gh ", "", "mix"], "tools_mode" => "warn"}
             })

    merged = Resolve.merge_agents(agents)
    assert merged["default"].tools == ["gh", "mix"]
    assert merged["default"].tools_mode == :warn
    assert merged["demo"].tools == ["node"]
    assert merged["demo"].tools_mode == :warn
  end

  test "merge_agents leaves file tools when Settings omits tools fields" do
    agents = %{
      "default" => %{command: "pi", tools: ["mix"], tools_mode: :warn}
    }

    assert {:ok, _} =
             Settings.put_section("agents", %{"default" => %{"model" => "only-model"}})

    merged = Resolve.merge_agents(agents)
    assert merged["default"].tools == ["mix"]
    assert merged["default"].tools_mode == :warn
    assert merged["default"].model == "only-model"
  end

  test "status reports local tracker ready without Settings" do
    status = Settings.status()
    assert status.tracker_ready? == true
    assert status.tracker_source == "file"
    assert is_boolean(status.provider_configured?)
    assert is_boolean(status.setup_complete?)
    assert is_integer(status.agent_count)
  end

  test "provider_configured? is true when only OPENCODE_API_KEY is set" do
    prev_or = System.get_env("OPENROUTER_API_KEY")
    prev_oc = System.get_env("OPENCODE_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-oc-only")

    on_exit(fn ->
      restore_env("OPENROUTER_API_KEY", prev_or)
      restore_env("OPENCODE_API_KEY", prev_oc)
    end)

    assert Settings.provider_configured?()
  end

  test "test_provider/1 names the selected adapter under HTTP stub" do
    prev = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-oc")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "glm-5.3-flash"}]}))
    end

    Application.put_env(:svarm, :provider_req_plug, plug)

    on_exit(fn ->
      Application.delete_env(:svarm, :provider_req_plug)
      restore_env("OPENCODE_API_KEY", prev)
    end)

    assert {:ok, %{count: 1, models: ["glm-5.3-flash"], provider: "opencode-go"}} =
             Settings.test_provider("opencode-go")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, val), do: System.put_env(name, val)
end
