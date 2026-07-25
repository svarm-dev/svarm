defmodule Svarm.SettingsTest do
  use ExUnit.Case, async: false

  alias Svarm.Settings
  alias Svarm.Settings.{Crypto, Resolve, Store}

  setup do
    Store.delete("provider.openrouter")
    Store.delete("tracker")
    Store.delete("agents")
    Store.delete("meta")
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

  test "status reports local tracker ready without Settings" do
    status = Settings.status()
    assert status.tracker_ready? == true
    assert status.tracker_source == "file"
    assert is_boolean(status.provider_configured?)
    assert is_boolean(status.setup_complete?)
    assert is_integer(status.agent_count)
  end
end
