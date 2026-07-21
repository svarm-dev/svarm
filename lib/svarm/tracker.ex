defmodule Svarm.Tracker do
  @moduledoc """
  Behaviour for issue trackers. The orchestrator depends on this behaviour,
  never on specific implementations. Adapter modules implement these callbacks
  to bridge Svärm's internal model to external trackers (GitHub, Linear, etc.).

  Iron Law #1: Adding a second tracker = one adapter module + config + tests,
  never a fork of the orchestrator.

  All callbacks receive a `config` map as the first argument. Fallible
  callbacks return tagged tuples: `{:ok, value}` | `{:error, reason}`.
  """
  alias Svarm.Issue

  @doc """
  Returns eligible issues for dispatch.
  Returns `{:ok, [Issue.t()]}` or `{:error, reason}`.
  """
  @callback list_eligible(config :: map()) :: {:ok, [Issue.t()]} | {:error, term()}

  @doc """
  Returns a single issue by its Svärm-internal ID.
  Returns `{:ok, Issue.t()}` or `{:error, :not_found}`.
  """
  @callback get_issue(config :: map(), id :: String.t()) :: {:ok, Issue.t()} | {:error, term()}

  @doc """
  Returns all issues matching the given filters (keyword list).
  Returns `{:ok, [Issue.t()]}` or `{:error, reason}`.
  """
  @callback list_issues(config :: map(), filters :: keyword()) ::
              {:ok, [Issue.t()]} | {:error, term()}

  @doc """
  Creates a new issue from the given attribute map.
  Returns `{:ok, Issue.t()}` or `{:error, reason}`.
  """
  @callback create_issue(config :: map(), attrs :: map()) :: {:ok, Issue.t()} | {:error, term()}

  @doc """
  Updates the status of an issue. Returns `:ok`.
  """
  @callback update_status(config :: map(), id :: String.t(), status :: String.t()) :: :ok

  @doc """
  Updates the retry attempt counter for an issue. Returns `:ok`.
  """
  @callback update_attempts(config :: map(), id :: String.t(), attempts :: integer()) :: :ok

  @doc """
  Claims an issue for dispatch. Returns `:ok`.
  """
  @callback claim(config :: map(), id :: String.t()) :: :ok

  @doc """
  Deletes all issues. Used in tests and demo seeding. Returns `:ok`.
  """
  @callback delete_all(config :: map()) :: :ok

  @doc """
  Posts a run summary to the tracker after a terminal outcome.
  Each adapter owns its own rendering (GitHub: markdown comment,
  Linear: comment via GraphQL, Jira: ADF comment, Local: no-op).

  The summary map contains tracker-agnostic data:
    %{run_id, task_id, result, duration_ms, agent_name, agent_role,
      adapter, model, provider, cost, branch, exit_code}

  Returns `:ok` on success (idempotent — repeat calls with same
  run_id must be safe). Returns `{:error, reason}` on failure.
  """
  @callback post_run_summary(config :: map(), id :: String.t(), summary :: map()) ::
              :ok | {:error, term()}
end
