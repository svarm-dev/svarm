defmodule Svarm.CiEvidenceOrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Test.Wait

  defp wait_until(fun, opts \\ []), do: Wait.until(fun, opts)

  defp flush_orchestrator do
    _ = :sys.get_state(Orchestrator)
    :ok
  end

  defmodule StubChecks do
    def summarize_pr_checks(_o, _r, n, _config, _opts \\ []) do
      calls = Application.get_env(:svarm, :ci_evidence_checks_calls, [])
      Application.put_env(:svarm, :ci_evidence_checks_calls, [n | calls])

      Application.get_env(:svarm, :ci_evidence_checks_result) ||
        {:error, :not_configured}
    end
  end

  defmodule ReviewTracker do
    def list_eligible(_config), do: {:ok, []}

    def list_issues(_config, filters \\ []) do
      if Application.get_env(:svarm, :ci_evidence_list_issues_empty, false) do
        {:ok, []}
      else
        issues = Application.get_env(:svarm, :ci_evidence_issues, %{}) |> Map.values()
        status = Keyword.get(filters, :status)
        issues = if status, do: Enum.filter(issues, &(&1.status == status)), else: issues
        {:ok, issues}
      end
    end

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
    Application.put_env(:svarm, :ci_evidence_checks_calls, [])
    Application.put_env(:svarm, :ci_evidence_list_issues_empty, false)

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
      Application.delete_env(:svarm, :ci_evidence_checks_calls)
      Application.delete_env(:svarm, :ci_evidence_list_issues_empty)

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
    # Evidence-only / resume disabled must not fingerprint — same SHA
    # later failing would :noop CI resume (#44) if we wrote it here.
    refute coord.ci_last_head_sha == "deadbeef"
    assert coord.ci_last_head_sha == nil
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

  test "pending then failed on same SHA resumes when ci_resume is enabled" do
    task_id = "ci_ev_pending_then_fail"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/7",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 7,
        ci_resume_count: 0
      })

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | ci_resume_caps: %{enabled: true, max_attempts: 3, skip_draft: true},
          completed: MapSet.put(state.completed, task_id)
      }
    end)

    Application.put_env(
      :svarm,
      :ci_evidence_checks_result,
      {:ok,
       %{
         conclusion: :pending,
         head_sha: "sha_a",
         failed_names: [],
         summary: "CI in progress",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_last_conclusion: "pending"}, Coordination.get(task_id))
           end)

    after_pending = Coordination.get(task_id)
    assert after_pending.ci_last_conclusion == "pending"
    assert after_pending.ci_context_summary =~ "CI in progress"
    assert %DateTime{} = after_pending.ci_checked_at
    assert after_pending.ci_last_head_sha == nil
    assert after_pending.ci_resume_count == 0

    assert get_in(Application.get_env(:svarm, :ci_evidence_issues), [task_id, :status]) ==
             "review"

    Application.put_env(
      :svarm,
      :ci_evidence_checks_result,
      {:ok,
       %{
         conclusion: :failed,
         head_sha: "sha_a",
         failed_names: ["mix"],
         summary: "CI failed: mix",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_resume_count: 1}, Coordination.get(task_id))
           end)

    after_fail = Coordination.get(task_id)
    assert after_fail.ci_resume_count == 1
    assert after_fail.ci_last_head_sha == "sha_a"

    assert get_in(Application.get_env(:svarm, :ci_evidence_issues), [task_id, :status]) ==
             "todo"
  end

  test "always-on Checks poll considers only current review tickets" do
    for i <- 1..5 do
      id = "ci_ev_done_#{i}"
      put_issue(id, "done")

      {:ok, row} =
        Coordination.upsert(id, %{
          pr_url: "https://github.com/o/r/pull/#{i}",
          pr_owner: "o",
          pr_repo: "r",
          pr_number: i
        })

      # Older than the review row so unbounded list_with_pr (updated_at ASC)
      # would fill the 3-slot window with done tickets.
      older =
        DateTime.utc_now()
        |> DateTime.add(-3600 * i, :second)
        |> DateTime.truncate(:second)

      Repo.update!(Ecto.Changeset.change(row, updated_at: older))
    end

    review_id = "ci_ev_review_live"
    put_issue(review_id)

    {:ok, _} =
      Coordination.upsert(review_id, %{
        pr_url: "https://github.com/o/r/pull/42",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 42
      })

    Application.put_env(
      :svarm,
      :ci_evidence_checks_result,
      {:ok,
       %{
         conclusion: :passed,
         head_sha: "live",
         failed_names: [],
         summary: "CI passed (review only)",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_last_conclusion: "passed"}, Coordination.get(review_id))
           end)

    assert Application.get_env(:svarm, :ci_evidence_checks_calls) == [42]

    review = Coordination.get(review_id)
    assert review.ci_last_conclusion == "passed"
    assert review.ci_context_summary =~ "review only"
    assert %DateTime{} = review.ci_checked_at

    for i <- 1..5 do
      done = Coordination.get("ci_ev_done_#{i}")
      assert done.ci_last_conclusion == nil
      assert done.ci_checked_at == nil
    end
  end

  test "empty current-review set does not poll any PR rows" do
    # list_issues({:ok, []}) must not fall back to unbounded list_with_pr.
    # Seed only a live review+PR that get_issue/review_status? would accept.
    # Extra older done+PR rows would fill the 3-slot take() window first,
    # so a fallback would still skip Checks and this test would stay green.
    Application.put_env(:svarm, :ci_evidence_list_issues_empty, true)

    hidden_review = "ci_ev_hidden_review"
    put_issue(hidden_review)

    {:ok, _} =
      Coordination.upsert(hidden_review, %{
        pr_url: "https://github.com/o/r/pull/199",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 199
      })

    Application.put_env(
      :svarm,
      :ci_evidence_checks_result,
      {:ok,
       %{
         conclusion: :passed,
         head_sha: "should-not-poll",
         failed_names: [],
         summary: "should not run",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)
    flush_orchestrator()

    assert Application.get_env(:svarm, :ci_evidence_checks_calls) == []

    hidden = Coordination.get(hidden_review)
    assert hidden.ci_last_conclusion == nil
    assert hidden.ci_checked_at == nil
  end
end
