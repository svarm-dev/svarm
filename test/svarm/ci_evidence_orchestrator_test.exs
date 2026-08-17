defmodule Svarm.CiEvidenceOrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Test.Wait

  defp wait_until(fun, opts \\ []), do: Wait.until(fun, opts)

  defmodule StubChecks do
    def summarize_pr_checks(_o, _r, _n, _config, _opts \\ []) do
      Application.get_env(:svarm, :ci_evidence_checks_result) ||
        {:error, :not_configured}
    end
  end

  defmodule ReviewTracker do
    def list_eligible(_config), do: {:ok, []}

    def get_issue(_config, id) do
      issues = Application.get_env(:svarm, :ci_evidence_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :not_found}
      end
    end

    def update_status(_config, id, status) do
      issues = Application.get_env(:svarm, :ci_evidence_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} ->
          Application.put_env(
            :svarm,
            :ci_evidence_issues,
            Map.put(issues, id, %{issue | status: status})
          )

          :ok

        :error ->
          :ok
      end
    end

    def update_attempts(_config, _id, _n), do: :ok
    def post_run_summary(_config, _id, _summary), do: :ok
  end

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Coordination)
    Application.put_env(:svarm, :ci_evidence_issues, %{})
    Application.put_env(:svarm, :ci_evidence_checks_result, nil)

    original = :sys.get_state(Orchestrator)
    prev_checks = Application.get_env(:svarm, :github_checks_module)
    Application.put_env(:svarm, :github_checks_module, StubChecks)

    # Isolate orchestrator from real tracker / resume during this suite.
    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | tracker: ReviewTracker,
          tracker_config: %{kind: :github, owner: "o", repo: "r", api_key: "t"},
          ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true},
          running: %{},
          claimed: MapSet.new()
      }
    end)

    on_exit(fn ->
      Application.delete_env(:svarm, :ci_evidence_issues)
      Application.delete_env(:svarm, :ci_evidence_checks_result)

      if prev_checks do
        Application.put_env(:svarm, :github_checks_module, prev_checks)
      else
        Application.delete_env(:svarm, :github_checks_module)
      end

      if Process.whereis(Orchestrator) do
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end)

    :ok
  end

  defp put_issue(task_id, status \\ "review") do
    issues = Application.get_env(:svarm, :ci_evidence_issues, %{})

    Application.put_env(
      :svarm,
      :ci_evidence_issues,
      Map.put(issues, task_id, %{id: task_id, status: status, title: "t"})
    )
  end

  test "poll stores CI evidence when resume is disabled" do
    task_id = "ci_ev_pass"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/1",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 1
      })

    Application.put_env(
      :svarm,
      :ci_evidence_checks_result,
      {:ok,
       %{
         conclusion: :passed,
         head_sha: "deadbeef",
         failed_names: [],
         summary: "CI passed (1 checks)",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_last_conclusion: "passed"}, Coordination.get(task_id))
           end)

    coord = Coordination.get(task_id)
    assert coord.ci_last_conclusion == "passed"
    assert coord.ci_context_summary =~ "CI passed"
    assert %DateTime{} = coord.ci_checked_at
    assert coord.ci_last_head_sha == "deadbeef"
    # Resume disabled: must not reopen
    assert get_in(Application.get_env(:svarm, :ci_evidence_issues), [task_id, :status]) ==
             "review"
  end

  test "API error stores unknown without blocking the tick" do
    task_id = "ci_ev_unknown"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/2",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 2
      })

    Application.put_env(:svarm, :ci_evidence_checks_result, {:error, :boom})

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_last_conclusion: "unknown"}, Coordination.get(task_id))
           end)

    coord = Coordination.get(task_id)
    assert coord.ci_last_conclusion == "unknown"
    assert coord.ci_context_summary == "CI status unavailable"
    assert %DateTime{} = coord.ci_checked_at
  end
end
