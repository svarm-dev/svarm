defmodule Svarm.StopReason do
  @moduledoc """
  Why a run stopped for a human, in the words the board shows.

  Every reason in the table below has a label in
  `Svarm.Board.wait_reason_label/1` with the same text, and the tracker comment
  reads this same table. A reason's wording therefore lives in one place. The
  board renders only the wait reasons its columns list, a smaller set than the
  statuses a workflow may make terminal.

  Which statuses are terminal is operator-configurable.
  `tracker.terminal_states` in WORKFLOW.md (see `Svarm.Workflow.Config`)
  defaults to `done`, `failed`, and `review`, and an operator can list further
  statuses. That is why `:blocked` and `:no_change_needed` are reachable
  rather than dead.

  A status without an entry (`done`, or an unknown string) yields `nil`, so
  callers omit the line instead of inventing wording.
  """

  @reasons %{
    review: %{status: "review", text: "Needs review"},
    failed: %{status: "failed", text: "Failed"},
    blocked: %{status: "blocked", text: "Blocked"},
    no_change_needed: %{status: "no_change_needed", text: "No change needed"}
  }

  @doc """
  Stop reason for a terminal tracker status.

  Returns `nil` when the status is not a stop reason.
  """
  @spec for_status(term()) :: atom() | nil
  def for_status(status) when is_binary(status) do
    Enum.find_value(@reasons, fn
      {reason, %{status: ^status}} -> reason
      _entry -> nil
    end)
  end

  def for_status(_status), do: nil

  @doc """
  Plain-language text for a stop reason, or `nil` when the reason has none.
  """
  @spec text(term()) :: String.t() | nil
  def text(reason) do
    case Map.fetch(@reasons, reason) do
      {:ok, %{text: text}} -> text
      :error -> nil
    end
  end
end
