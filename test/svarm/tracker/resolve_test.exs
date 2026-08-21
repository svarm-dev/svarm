defmodule Svarm.Tracker.ResolveTest do
  use ExUnit.Case, async: false

  alias Svarm.Settings
  alias Svarm.Settings.Store
  alias Svarm.Tracker
  alias Svarm.Tracker.Resolve

  setup do
    cleanup = fn ->
      Store.delete("tracker")
    end

    cleanup.()
    on_exit(cleanup)
    :ok
  end

  describe "adapter_and_config/1" do
    test "maps local kind to Tracker.Local with local config keys" do
      assert {Tracker.Local, config} =
               Resolve.adapter_and_config(config: %{kind: :local, ignored_assignees: ["bot"]})

      assert config.kind == :local
      assert config.active_states == ["todo", "in_progress"]
      assert config.terminal_states == ["done", "failed", "review"]
      assert config.ignored_assignees == ["bot"]
    end

    test "maps github kind to Tracker.GitHub and keeps owner/repo" do
      tc = %{kind: :github, owner: "acme", repo: "widgets", api_key: "ghp_test"}

      assert {Tracker.GitHub, config} = Resolve.adapter_and_config(config: tc)
      assert config.kind == :github
      assert config.owner == "acme"
      assert config.repo == "widgets"
      assert config.api_key == "ghp_test"
    end

    test "unknown kind falls back to Local" do
      assert {Tracker.Local, %{kind: :local}} =
               Resolve.adapter_and_config(config: %{kind: :linear})
    end

    test "active Settings overlay wins over a local workflow base" do
      assert {:ok, _} =
               Settings.put_tracker(%{
                 "kind" => "github",
                 "owner" => "acme",
                 "repo" => "widgets",
                 "api_key" => "ghp_test",
                 "auth" => "token"
               })

      assert {Tracker.GitHub, config} = Resolve.adapter_and_config()
      assert config.kind == :github
      assert config.owner == "acme"
      assert config.repo == "widgets"
    end

    test "explicit config skips Settings overlay" do
      assert {:ok, _} =
               Settings.put_tracker(%{
                 "kind" => "github",
                 "owner" => "acme",
                 "repo" => "widgets",
                 "api_key" => "ghp_test",
                 "auth" => "token"
               })

      assert {Tracker.GitHub, _} = Resolve.adapter_and_config()

      assert {Tracker.Local, config} =
               Resolve.adapter_and_config(config: %{kind: :local})

      assert config.kind == :local
    end
  end

  describe "supports?/2" do
    test "Local opts out of CI, review, and connectivity probe" do
      refute Resolve.supports?(Tracker.Local, :ci_poll)
      refute Resolve.supports?(Tracker.Local, :review_poll)
      refute Resolve.supports?(Tracker.Local, :connectivity_probe)
    end

    test "GitHub opts in to CI, review, and connectivity probe" do
      assert Resolve.supports?(Tracker.GitHub, :ci_poll)
      assert Resolve.supports?(Tracker.GitHub, :review_poll)
      assert Resolve.supports?(Tracker.GitHub, :connectivity_probe)
    end

    test "adapters without capabilities/0 still poll CI and reviews" do
      assert Resolve.supports?(UndeclaredTracker, :ci_poll)
      assert Resolve.supports?(UndeclaredTracker, :review_poll)
      refute Resolve.supports?(UndeclaredTracker, :connectivity_probe)
    end
  end

  describe "from_opts/1" do
    test "explicit tracker wins without resolving kind" do
      assert {UndeclaredTracker, %{k: 1}} =
               Resolve.from_opts(tracker: UndeclaredTracker, tracker_config: %{k: 1})
    end

    test "missing tracker uses the active adapter" do
      assert {Tracker.Local, config} = Resolve.from_opts([])
      assert config.kind == :local
    end
  end

  defmodule UndeclaredTracker do
    def list_eligible(_config), do: {:ok, []}
  end
end
