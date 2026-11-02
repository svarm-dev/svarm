defmodule Svarm.OrchestratorScopeTest do
  @moduledoc """
  Scoped (`{board_id, external_id}`) orchestration keys after a catalog import.

  The board matches cards by public task id, and reconcile has to see work that
  is claimed or retrying rather than only running. These cover the three
  regressions that showed up when the same external ticket can exist on more
  than one board.
  """

  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge}
  alias Svarm.Orchestrator.{Reconcile, Resume, Scope, Status}
  alias Svarm.Settings.Catalog.Store

  defmodule TerminalTracker do
    def get_issue(config, id) do
      send(config.owner, {:lookup, id})
      {:ok, %{id: id, status: "done"}}
    end

    def update_status(_config, _id, _status), do: :ok
  end

  defmodule ReviewTracker do
    # capabilities/0 absent → CI/review poll is supported, same as a test double.
    def list_issues(config, _filters) do
      notify({:list_issues, config})
      {:ok, [%{id: config.issue_id, status: "review"}]}
    end

    def get_issue(_config, id) do
      notify({:lookup, id})
      {:ok, %{id: id, status: "review"}}
    end

    def update_status(_config, id, status) do
      notify({:status, id, status})
      :ok
    end

    defp notify(message) do
      if pid = Application.get_env(:svarm, :orchestrator_scope_test_pid) do
        send(pid, message)
      end

      :ok
    end
  end

  setup do
    KanbanBridge.delete_all_tasks()
    clear_catalog()

    Application.put_env(:svarm, :orchestrator_scope_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:svarm, :orchestrator_scope_test_pid)
      clear_catalog()
      KanbanBridge.delete_all_tasks()
    end)

    :ok
  end

  describe "reconcile" do
    test "a scoped retry entry is released when the ticket goes terminal" do
      key = {"alpha", "EXT-RETRY"}
      timer = Process.send_after(self(), :never, 60_000)

      state =
        base_state(%{
          retry_attempts: %{
            key => %{
              attempt: 1,
              identifier: key,
              issue_id: "EXT-RETRY",
              board_id: "alpha",
              task: %{id: "EXT-RETRY", board_id: "alpha", external_task_id: "EXT-RETRY"},
              tracker: TerminalTracker,
              tracker_config: %{owner: self()},
              timer: timer,
              due_at_mono: System.monotonic_time(:millisecond) + 60_000
            }
          },
          claimed: MapSet.new([key])
        })

      assert %{claimed: claimed, retry_attempts: retries} = Reconcile.sync_tracker(state)

      assert_receive {:lookup, "EXT-RETRY"}
      refute MapSet.member?(claimed, key)
      assert retries == %{}
      assert Process.read_timer(timer) == false
    end

    test "a scoped claimed-only key is released when the ticket goes terminal" do
      insert_boards([
        %{
          "id" => "alpha",
          "name" => "alpha",
          "enabled" => true,
          "tracker" => %{"kind" => "local"}
        }
      ])

      row =
        KanbanBridge.create_task(%{
          title: "claimed only",
          status: "done",
          assignee: "demo",
          board_id: "alpha",
          external_task_id: "EXT-CLAIMED"
        })

      key = {"alpha", "EXT-CLAIMED"}
      state = base_state(%{claimed: MapSet.new([key])})

      refute Map.has_key?(state.running, key)
      refute Map.has_key?(state.retry_attempts, key)
      assert Scope.issue_id_for("alpha", "EXT-CLAIMED") == {:ok, row.id}

      assert %{claimed: claimed} = Reconcile.sync_tracker(state)
      refute MapSet.member?(claimed, key)
    end

    test "a scoped claimed-only key with no task row is left alone" do
      insert_boards([
        %{
          "id" => "alpha",
          "name" => "alpha",
          "enabled" => true,
          "tracker" => %{"kind" => "local"}
        }
      ])

      key = {"alpha", "EXT-MISSING"}
      state = base_state(%{claimed: MapSet.new([key])})

      assert Scope.issue_id_for("alpha", "EXT-MISSING") == :error
      assert %{claimed: claimed} = Reconcile.sync_tracker(state)
      assert MapSet.member?(claimed, key)
    end
  end

  describe "status" do
    test "running and retry ids stay public task ids after a scoped run key" do
      running_entry = %{
        task: %{id: "sva_row_1", board_id: "alpha", external_task_id: "EXT-1", assignee: "demo"},
        board_id: "alpha",
        started_mono_ms: 1_000,
        pid: self()
      }

      retry_entry = %{
        task: %{id: "sva_row_2", board_id: "alpha", external_task_id: "EXT-2", assignee: "demo"},
        issue_id: "sva_row_2",
        board_id: "alpha"
      }

      state =
        base_state(%{
          running: %{{"alpha", "EXT-1"} => running_entry},
          retry_attempts: %{{"alpha", "EXT-2"} => retry_entry},
          claimed: MapSet.new([{"alpha", "EXT-1"}, {"alpha", "EXT-2"}])
        })

      summary = Status.summary(state)

      assert summary.running_ids == ["sva_row_1"]
      assert summary.retry_ids == ["sva_row_2"]
      assert Map.keys(summary.running_started) == ["sva_row_1"]
      assert summary.board_ids == ["alpha"]
      assert summary.running == 1
      assert summary.retrying == 1
    end
  end

  describe "resume" do
    test "an in-flight scoped run is not reopened by the CI poll" do
      assert {:ok, _} =
               Coordination.upsert("EXT-1", %{
                 pr_owner: "svarm-dev",
                 pr_repo: "svarm",
                 pr_number: 7
               })

      running_entry = %{
        task: %{id: "EXT-1", board_id: "alpha", external_task_id: "EXT-1", assignee: "demo"},
        board_id: "alpha",
        started_mono_ms: 1_000,
        pid: self()
      }

      state =
        base_state(%{
          tracker: ReviewTracker,
          tracker_config: %{owner: "svarm-dev", repo: "svarm", issue_id: "EXT-1"},
          running: %{{"alpha", "EXT-1"} => running_entry},
          claimed: MapSet.new([{"alpha", "EXT-1"}])
        })

      assert %{running: running} = Resume.ci(state)
      assert map_size(running) == 1
      assert_received {:list_issues, _config}
      refute_received {:lookup, _}
      refute_received {:status, _, _}
    end
  end

  defp base_state(overrides) do
    Map.merge(
      %{
        tracker: TerminalTracker,
        tracker_config: %{owner: self()},
        approval: %{mode: :off, trusted_assignees: MapSet.new()},
        running: %{},
        claimed: MapSet.new(),
        completed: MapSet.new(),
        retry_attempts: %{},
        approved_once: MapSet.new(),
        issue_cache: %{},
        last_run_entries: %{},
        poll_interval_ms: 1_000,
        max_concurrent: 3,
        last_tick_mono_ms: 0,
        budget_caps: %{},
        budget_mode: :hard,
        last_budget_block: nil,
        ci_resume_caps: %{enabled: false},
        review_resume_caps: %{enabled: false},
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"]
      },
      overrides
    )
  end

  defp insert_boards(boards) do
    assert {:ok, _} = Store.insert_revision(%{"boards" => boards})
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
end
