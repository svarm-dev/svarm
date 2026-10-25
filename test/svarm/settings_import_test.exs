defmodule Svarm.SettingsImportTest do
  use ExUnit.Case, async: false

  alias Svarm.Orchestrator
  alias Svarm.Settings
  alias Svarm.Settings.Catalog.Store
  alias Svarm.Settings.Store, as: SettingsStore
  alias Svarm.Tracker
  alias Svarm.Tracker.Resolve, as: TrackerResolve

  setup do
    previous_workflow = :sys.get_state(Svarm.Workflow.Store)
    previous_token = System.get_env("GITHUB_TOKEN")

    clear_catalog()
    SettingsStore.delete("tracker")
    SettingsStore.delete("agents")
    SettingsStore.delete("provider.openrouter")

    on_exit(fn ->
      :sys.replace_state(Svarm.Workflow.Store, fn _ -> previous_workflow end)
      restore_env("GITHUB_TOKEN", previous_token)
      clear_catalog()
      SettingsStore.delete("tracker")
      SettingsStore.delete("agents")
      SettingsStore.delete("provider.openrouter")
      Orchestrator.reload_config()
    end)

    :ok
  end

  test "no revision follows a workflow tracker kind change" do
    assert Store.latest_revision() == nil

    put_workflow("github", "file-org", "file-repo")
    assert {Tracker.GitHub, github} = TrackerResolve.adapter_and_config()
    assert github.kind == :github
    assert github.owner == "file-org"

    put_workflow("local")
    assert {Tracker.Local, local} = TrackerResolve.adapter_and_config()
    assert local.kind == :local
    refute Map.has_key?(local, :board_id)
  end

  test "import creates one default board and a second call does not write revision 2" do
    put_workflow("local")

    assert {:ok, saved} = Settings.import_legacy()
    assert saved.revision == 1
    assert Enum.map(saved.boards, & &1.id) == ["default"]
    assert Store.latest_revision() == 1

    assert {:ok, :already_imported} = Settings.import_legacy()
    assert Store.latest_revision() == 1
    assert {:ok, again} = Store.get(1)
    assert Enum.map(again.boards, & &1.id) == ["default"]
  end

  test "after import a workflow tracker kind change does not change the resolved tracker" do
    put_workflow("local")
    assert {:ok, _} = Settings.import_legacy()

    put_workflow("github", "later-org", "later-repo")

    assert {Tracker.Local, config} = TrackerResolve.adapter_and_config()
    assert config.kind == :local
    refute config[:owner] == "later-org"

    assert {:ok, summary} = Orchestrator.reload_config()
    assert summary.tracker_kind == :local
  end

  test "imported catalog rows keep credential ids and no token-looking fields" do
    token = "ghp_" <> String.duplicate("a", 20)
    provider_token = "sk-" <> String.duplicate("b", 20)
    System.put_env("GITHUB_TOKEN", token)

    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "auth" => "token",
               "api_key" => token
             })

    assert {:ok, _} = Settings.put_provider(%{"api_key" => provider_token})

    put_workflow(
      "github",
      "acme",
      "widgets",
      "https://user:#{token}@git.example.com/acme/widgets.git"
    )

    assert {:ok, saved} = Settings.import_legacy()
    board = Enum.find(saved.boards, &(&1.id == "default"))
    encoded = Jason.encode!(saved)

    refute encoded =~ token
    refute encoded =~ provider_token
    refute Map.has_key?(board.tracker, "api_key")
    refute Map.has_key?(board.tracker, "token")
    refute Map.has_key?(board.tracker, "private_key")
    refute Map.has_key?(board.remote, "token")
    assert is_binary(board.remote["url"])
    refute String.contains?(board.remote["url"], token)
    assert board.tracker["kind"] == "github"
    assert board.tracker["credential_id"] == "tracker"
    assert board.tracker["owner"] == "acme"

    provider = Enum.find(saved.providers, &(&1.id == "openrouter"))
    assert provider.credential_id == "provider.openrouter"
    refute Map.has_key?(provider, :api_key)

    Enum.each(saved.harnesses, fn harness ->
      refute Map.has_key?(harness.env, "GITHUB_TOKEN")
      refute Map.has_key?(harness.env, "OPENROUTER_API_KEY")
    end)

    assert Settings.get_secret("tracker", "api_key") == token
    assert Settings.get_secret("provider.openrouter", "api_key") == provider_token

    assert {Tracker.GitHub, config} = TrackerResolve.adapter_and_config()
    assert config.kind == :github
    assert config.api_key == token
    assert config.owner == "acme"
  end

  test "put_section tracker and agents return imported while provider secrets still rotate" do
    put_workflow("github", "acme", "widgets")

    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_" <> String.duplicate("d", 20)
             })

    assert {:ok, _} = Settings.import_legacy()

    assert {:error, :imported} =
             Settings.put_section("tracker", %{"kind" => "local", "owner" => "nope"})

    assert {:error, :imported} =
             Settings.put_section("agents", %{"default" => %{"model" => "other"}})

    rotated = "sk-" <> String.duplicate("c", 20)
    assert {:ok, _} = Settings.put_provider(%{"api_key" => rotated})
    assert Settings.get_secret("provider.openrouter", "api_key") == rotated

    assert {Tracker.GitHub, config} = TrackerResolve.adapter_and_config()
    assert config.kind == :github
    assert config.owner == "acme"
    refute config.owner == "nope"
  end

  test "a failed first revision leaves no catalog row" do
    assert {:error, :unknown_harness} =
             Store.insert_first_revision(%{
               "boards" => [%{"id" => "default", "name" => "Default"}],
               "bindings" => [%{"board_id" => "default", "harness_id" => "missing"}]
             })

    assert Store.latest_revision() == nil
    assert Store.get(1) == :error
  end

  defp put_workflow(kind, owner \\ nil, repo \\ nil, remote \\ nil) do
    tracker = %{"kind" => kind, "active_states" => ["todo"], "terminal_states" => ["done"]}
    tracker = if owner, do: Map.put(tracker, "owner", owner), else: tracker
    tracker = if repo, do: Map.put(tracker, "repo", repo), else: tracker

    config = %{"tracker" => tracker}
    config = if remote, do: Map.put(config, "workspace", %{"git_remote" => remote}), else: config

    :sys.replace_state(Svarm.Workflow.Store, fn state ->
      %{
        state
        | workflow: %Svarm.Workflow{config: config, prompt_template: "work", path: "test.md"}
      }
    end)
  end

  defp clear_catalog do
    for table <- [
          "catalog_board_bindings",
          "catalog_boards",
          "catalog_harness_profiles",
          "catalog_toolchain_profiles",
          "catalog_provider_profiles",
          "catalog_revisions"
        ] do
      Svarm.Repo.query!("DELETE FROM #{table}")
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
