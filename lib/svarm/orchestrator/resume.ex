defmodule Svarm.Orchestrator.Resume do
  @moduledoc """
  CI Checks poll (board Evidence + optional resume) and review-resume poll.

  CI poll: on trackers with `:ci_poll`, refresh Checks summary onto
  coordination for Review Station Evidence. When `ci_resume.enabled`, also
  re-open for a fresh agent run with failure context until the circuit
  opens after N attempts. See `Svarm.CiResume`.

  Review-resume: poll PR reviews for managed PRs in review and record
  changes-requested state. When `review_resume.enabled`, the first
  transition into changes-requested re-opens for a fresh run, sharing the
  CI resume circuit. See `Svarm.ReviewResume`.

  Both loops gate on Tracker capability flags, not adapter identity.
  """

  require Logger

  alias Svarm.{
    CiResume,
    Coordination,
    Events,
    ReviewResume,
    Tracker
  }

  alias Svarm.Orchestrator.{Issues, Status}
  alias Svarm.Tracker.GitHub.Checks
  alias Svarm.Tracker.GitHub.Reviews

  # Bound Checks / review polls per tick so the GenServer mailbox stays responsive.
  @ci_resume_max_per_tick 3
  @review_resume_max_per_tick 3

  @doc false
  def ci(state) do
    if Tracker.Resolve.supports?(state.tracker, :ci_poll) do
      caps = state.ci_resume_caps || %{enabled: false, max_attempts: 3, skip_draft: true}

      state
      |> ci_poll_pr_rows()
      |> Enum.take(@ci_resume_max_per_tick)
      |> Enum.reduce(state, fn coord, acc ->
        maybe_ci_poll_one(acc, coord, caps)
      end)
    else
      state
    end
  end

  @doc false
  def review(state) do
    if Tracker.Resolve.supports?(state.tracker, :review_poll) do
      poll_review_resume(state)
    else
      state
    end
  end

  # Checks poll is review-scoped. Done+PR rows stay oldest and would starve
  # the 3-slot window if we scanned list_with_pr unbounded. Empty/missing
  # review ids → no poll (do not copy review-resume's unbounded fallback).
  defp ci_poll_pr_rows(state) do
    case review_task_ids(state) do
      [_ | _] = ids ->
        Coordination.list_with_pr(
          limit: @ci_resume_max_per_tick * 2,
          task_ids: ids
        )

      _ ->
        []
    end
  end

  defp maybe_ci_poll_one(state, coord, caps) do
    task_id = coord.task_id

    cond do
      Map.has_key?(state.running, task_id) or MapSet.member?(state.claimed, task_id) ->
        state

      not pr_matches_tracker?(coord, state.tracker_config) ->
        Logger.debug("ci_poll: skip #{task_id} — PR repo does not match tracker")
        state

      not review_status?(state, task_id) ->
        state

      true ->
        evaluate_ci_for_task(state, coord, caps)
    end
  end

  defp pr_matches_tracker?(coord, %{owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo) do
    Coordination.allowed_repo?(
      %{pr_owner: coord.pr_owner, pr_repo: coord.pr_repo},
      owner: owner,
      repo: repo
    )
  end

  defp pr_matches_tracker?(_coord, _config), do: true

  defp review_status?(state, task_id) do
    case Issues.get(state.tracker, state.tracker_config, task_id) do
      {:ok, %{status: "review"}} -> true
      _ -> false
    end
  end

  defp evaluate_ci_for_task(state, coord, caps) do
    checks_mod = Application.get_env(:svarm, :github_checks_module, Checks)

    case checks_mod.summarize_pr_checks(
           coord.pr_owner,
           coord.pr_repo,
           coord.pr_number,
           state.tracker_config,
           skip_draft: Map.get(caps, :skip_draft, true)
         ) do
      {:ok, summary} ->
        decision =
          if Map.get(caps, :enabled, false) do
            CiResume.evaluate(coord, summary, caps)
          else
            :evidence_only
          end

        # Persist conclusion / summary / checked_at on every successful poll.
        # Never write ci_last_head_sha here — that fingerprint is only set
        # after a successful resume reopen (commit_ci_resume). Writing it on
        # :wait / :evidence_only would make a later same-SHA failure :noop.
        store_ci_evidence(coord.task_id, summary)

        case decision do
          :evidence_only -> state
          other -> apply_ci_decision(state, coord, summary, caps, other)
        end

      {:error, reason} ->
        Logger.debug("ci_poll checks error for #{coord.task_id}: #{inspect(reason)}")
        store_ci_evidence_unknown(coord.task_id)
        state
    end
  end

  defp store_ci_evidence(task_id, summary) when is_map(summary) do
    conclusion =
      case Map.get(summary, :conclusion) do
        c when is_atom(c) -> Atom.to_string(c)
        c when is_binary(c) and c != "" -> c
        _ -> "unknown"
      end

    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      ci_last_conclusion: conclusion,
      ci_checked_at: checked_at,
      ci_context_summary: Map.get(summary, :summary)
    }

    case Coordination.upsert(task_id, attrs) do
      {:ok, updated} ->
        # Omit status so Events does not spam "[board] status → review" every poll.
        Events.broadcast_task_updated(%{
          id: task_id,
          reason: :ci_evidence,
          ci_conclusion: updated.ci_last_conclusion,
          ci_summary: updated.ci_context_summary,
          ci_checked_at: updated.ci_checked_at
        })

        :ok

      {:error, reason} ->
        Logger.debug("ci_evidence upsert failed for #{task_id}: #{inspect(reason)}")
        :error
    end
  end

  defp store_ci_evidence_unknown(task_id) when is_binary(task_id) do
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    case Coordination.upsert(task_id, %{
           ci_last_conclusion: "unknown",
           ci_checked_at: checked_at,
           ci_context_summary: "CI status unavailable"
         }) do
      {:ok, updated} ->
        Events.broadcast_task_updated(%{
          id: task_id,
          reason: :ci_evidence,
          ci_conclusion: updated.ci_last_conclusion,
          ci_summary: updated.ci_context_summary,
          ci_checked_at: updated.ci_checked_at
        })

        :ok

      {:error, _} ->
        :error
    end
  end

  defp apply_ci_decision(state, _coord, _summary, _caps, :noop), do: state

  defp apply_ci_decision(state, _coord, _summary, _caps, :wait), do: state

  defp apply_ci_decision(state, coord, summary, _caps, :resume) do
    # Reopen first; only fingerprint after status is active so a failed
    # reopen cannot burn the head_sha (evaluate would forever :noop).
    case reopen_for_resume(state, coord.task_id) do
      :ok ->
        commit_ci_resume(state, coord, summary)

      {:error, reason} ->
        Logger.warning(
          "ci_resume: reopen failed for #{coord.task_id}: #{inspect(reason)} (not fingerprinting)"
        )

        state
    end
  end

  defp apply_ci_decision(state, coord, summary, _caps, :circuit_open) do
    case Coordination.upsert(coord.task_id, %{
           ci_circuit_open: true,
           ci_last_conclusion: "failure",
           ci_last_head_sha: summary.head_sha || coord.ci_last_head_sha,
           ci_context_summary: summary.summary || coord.ci_context_summary,
           ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        Logger.warning("ci_resume: circuit open for #{coord.task_id} (CI retries exhausted)")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :ci_circuit
        })

        Status.broadcast(state)
        state

      {:error, reason} ->
        Logger.warning(
          "ci_resume: circuit upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp reopen_for_resume(state, task_id) do
    case state.tracker.update_status(state.tracker_config, task_id, "todo") do
      {:error, reason} -> {:error, reason}
      :ok -> confirm_reopened_active(state, task_id)
    end
  end

  defp confirm_reopened_active(state, task_id) do
    case Issues.get(state.tracker, state.tracker_config, task_id) do
      {:ok, %{status: status}} when is_binary(status) ->
        if status in state.active_states do
          :ok
        else
          {:error, {:still_not_active, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_ci_resume(state, coord, summary) do
    context = CiResume.context_summary(summary)
    count = (coord.ci_resume_count || 0) + 1

    case Coordination.upsert(coord.task_id, %{
           ci_resume_count: count,
           ci_last_head_sha: summary.head_sha,
           ci_last_conclusion: "failure",
           ci_context_summary: context,
           ci_circuit_open: false,
           ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        Logger.info(
          "ci_resume: re-opened #{coord.task_id} (attempt #{count}) sha=#{summary.head_sha}"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "todo",
          reason: :ci_resume
        })

        # One-shot: first-run approval already happened; do not re-gate every CI fix loop.
        %{
          state
          | completed: MapSet.delete(state.completed, coord.task_id),
            approved_once: MapSet.put(state.approved_once, coord.task_id)
        }

      {:error, reason} ->
        Logger.warning(
          "ci_resume: fingerprint upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp poll_review_resume(state) do
    {next, _polled} =
      state
      |> review_resume_pr_rows()
      |> Enum.reduce_while({state, 0}, &poll_review_resume_step/2)

    next
  end

  # Prefer tracker review ids so done rows cannot fill a bounded window.
  # HTTP 200 with an empty list may still miss configured labels, so we fall
  # back to `list_with_pr` with the same cap of 50 as the happy path. A tagged
  # `list_issues` error must not scan those rows — that was the swallowed-403
  # "poll everything" bug.
  defp review_resume_pr_rows(state) do
    case review_task_ids(state) do
      [_ | _] = ids ->
        Coordination.list_with_pr(
          limit: 50,
          include_circuit_open: true,
          task_ids: ids
        )

      :unavailable ->
        []

      _ ->
        Coordination.list_with_pr(include_circuit_open: true, limit: 50)
    end
  end

  defp review_task_ids(state) do
    if function_exported?(state.tracker, :list_issues, 2) do
      case state.tracker.list_issues(state.tracker_config, status: "review") do
        {:ok, [_ | _] = issues} -> Enum.map(issues, & &1.id)
        {:error, _} -> :unavailable
        _ -> nil
      end
    else
      nil
    end
  end

  defp poll_review_resume_step(_coord, {acc, n}) when n >= @review_resume_max_per_tick do
    {:halt, {acc, n}}
  end

  defp poll_review_resume_step(coord, {acc, n}) do
    {next, polled?} = maybe_review_resume_one(acc, coord)
    {:cont, {next, if(polled?, do: n + 1, else: n)}}
  end

  defp maybe_review_resume_one(state, coord) do
    task_id = coord.task_id

    cond do
      Map.has_key?(state.running, task_id) or MapSet.member?(state.claimed, task_id) ->
        {state, false}

      not pr_matches_tracker?(coord, state.tracker_config) ->
        Logger.debug("review_resume: skip #{task_id} — PR repo does not match tracker")
        {state, false}

      not review_status?(state, task_id) ->
        {state, false}

      true ->
        {evaluate_reviews_for_task(state, coord), true}
    end
  end

  defp evaluate_reviews_for_task(state, coord) do
    reviews_mod = Application.get_env(:svarm, :github_reviews_module, Reviews)

    case reviews_mod.summarize_pr_reviews(
           coord.pr_owner,
           coord.pr_repo,
           coord.pr_number,
           state.tracker_config
         ) do
      {:ok, summary} ->
        decision = ReviewResume.evaluate(coord, summary)

        state
        |> apply_review_decision(coord, summary, decision)
        |> apply_review_spawn(coord, decision)

      {:error, reason} ->
        Logger.debug("review_resume reviews error for #{coord.task_id}: #{inspect(reason)}")
        state
    end
  end

  defp apply_review_decision(state, _coord, _summary, :noop), do: state

  defp apply_review_decision(state, coord, summary, :record) do
    context = ReviewResume.context_summary(summary)

    case Coordination.upsert(coord.task_id, %{
           review_decision: "changes_requested",
           review_last_head_sha: summary.head_sha,
           review_context_summary: context
         }) do
      {:ok, _} ->
        Logger.info(
          "review_resume: changes requested for #{coord.task_id} sha=#{summary.head_sha}"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :review_changes_requested,
          review_decision: "changes_requested"
        })

        Status.broadcast(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: record upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_decision(state, coord, summary, :clear) do
    case Coordination.upsert(coord.task_id, %{
           review_decision: "none",
           review_last_head_sha: summary.head_sha || coord.review_last_head_sha,
           review_context_summary: nil
         }) do
      {:ok, _} ->
        Logger.info("review_resume: cleared changes-requested for #{coord.task_id}")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :review_changes_cleared,
          review_decision: "none"
        })

        Status.broadcast(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: clear upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_spawn(state, coord, detection) do
    caps = %{
      enabled: review_resume_enabled?(state),
      max_attempts: ci_resume_max_attempts(state)
    }

    case ReviewResume.spawn_evaluate(coord, detection, caps) do
      :noop ->
        state

      :resume ->
        apply_review_resume(state, coord)

      :circuit_open ->
        apply_review_circuit(state, coord)
    end
  end

  defp apply_review_resume(state, coord) do
    case reopen_for_resume(state, coord.task_id) do
      :ok ->
        commit_review_resume(state, coord)

      {:error, reason} ->
        Logger.warning(
          "review_resume: reopen failed for #{coord.task_id}: #{inspect(reason)} (not counting)"
        )

        state
    end
  end

  defp commit_review_resume(state, coord) do
    count = (coord.ci_resume_count || 0) + 1

    case Coordination.upsert(coord.task_id, %{
           ci_resume_count: count,
           ci_circuit_open: false
         }) do
      {:ok, _} ->
        Logger.info("review_resume: re-opened #{coord.task_id} (attempt #{count})")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "todo",
          reason: :review_resume
        })

        %{
          state
          | completed: MapSet.delete(state.completed, coord.task_id),
            approved_once: MapSet.put(state.approved_once, coord.task_id)
        }

      {:error, reason} ->
        Logger.warning(
          "review_resume: count upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_circuit(state, coord) do
    case Coordination.upsert(coord.task_id, %{ci_circuit_open: true}) do
      {:ok, _} ->
        Logger.warning(
          "review_resume: circuit open for #{coord.task_id} (shared resume retries exhausted)"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :ci_circuit
        })

        Status.broadcast(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: circuit upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp review_resume_enabled?(%{review_resume_caps: %{enabled: true}}), do: true
  defp review_resume_enabled?(_), do: false

  defp ci_resume_max_attempts(%{ci_resume_caps: %{max_attempts: n}})
       when is_integer(n) and n > 0,
       do: n

  defp ci_resume_max_attempts(_), do: 3
end
