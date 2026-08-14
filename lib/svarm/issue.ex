defmodule Svarm.Issue do
  @moduledoc """
  Normalized issue representation. All tracker adapters convert their
  external format to this struct. The orchestrator and web layer only
  ever see `%Svarm.Issue{}` — never tracker-specific shapes.
  """
  defstruct [
    # Svärm-internal ID (e.g., "sva_deadbeef")
    :id,
    # tracker-native ID (e.g., GitHub issue number)
    :source_id,
    :title,
    :body,
    # code | research | docs
    :type,
    # agent name
    :assignee,
    # possible values: in_progress | done | failed | review | pending_approval
    :status,
    # 0 = normal, 1 = high, etc.
    :priority,
    # retry count
    :attempts,
    # "svarm" or user identifier
    :created_by,
    # unix timestamp
    :created_at,
    # goal identifier
    :tenant,
    # tracker labels (GitHub labels, etc.)
    :labels,
    # :local | :github | :linear | :jira
    :tracker,
    # original tracker data, preserved for debugging. Never used in logic.
    :raw,
    # IDs of tasks that must complete before this one
    depends_on: [],
    # Mid-run Q&A wait (`"agent_question"` or nil)
    :wait_reason,
    # Pending agent question payload (string-key map) or nil
    :pending_question
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source_id: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          type: String.t(),
          assignee: String.t() | nil,
          status: String.t(),
          priority: integer(),
          attempts: integer(),
          created_by: String.t() | nil,
          created_at: integer() | nil,
          tenant: String.t() | nil,
          labels: [String.t()],
          depends_on: [String.t()],
          wait_reason: String.t() | nil,
          pending_question: map() | nil,
          tracker: atom(),
          raw: map() | nil
        }
end
