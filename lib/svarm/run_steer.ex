defmodule Svarm.RunSteer do
  @moduledoc """
  Operator steer for a live PiRPC session.

  Web and tests call this module only — not `AgentRunner` or `Workspace`.
  The PiRPC worker registers in `Svarm.RunSteer.Inbox` for the whole run;
  `inject/2` sends `{:steer, text}` and the worker writes JSONL `type: steer`
  unless a dialog is already parked (`waiting_ui`).

  CLI sessions never register. Mid-run Q&A must be answered first.
  """

  alias Svarm.{Board, KanbanBridge}

  @inbox Svarm.RunSteer.Inbox

  @type error :: :not_running | :unsupported | :empty | :question_pending

  @doc "Registry name for the live PiRPC worker (string task ids)."
  def inbox, do: @inbox

  @doc "Register the calling PiRPC worker for `task_id`."
  @spec register(String.t()) :: :ok
  def register(task_id) when is_binary(task_id) do
    unregister()

    case Registry.register(@inbox, task_id, :running) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc "Drop this process's steer inbox keys (safe if none)."
  @spec unregister() :: :ok
  def unregister do
    Registry.keys(@inbox, self())
    |> Enum.each(&Registry.unregister(@inbox, &1))

    :ok
  end

  @doc """
  Queue a steer on the live PiRPC worker.

  Returns `{:ok, :injected}` after the message is sent to the worker.
  Refuses when a question is already parked. A steer that races a park
  still lands in the mailbox; the PiRPC loop drops it while `waiting_ui`
  is set so it cannot flush mid-dialog.
  """
  @spec inject(String.t(), String.t()) :: {:ok, :injected} | {:error, error()}
  def inject(task_id, text) when is_binary(task_id) and is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        {:error, :empty}

      question_pending?(task_id) ->
        {:error, :question_pending}

      true ->
        send_steer(task_id, trimmed)
    end
  end

  @doc "User-facing flash for `inject/2` errors."
  @spec flash_error(error() | term()) :: String.t()
  def flash_error(:empty), do: "Steer text is empty."
  def flash_error(:not_running), do: "No live Pi RPC session to steer."
  def flash_error(:unsupported), do: "Steer is Pi RPC on a live run."
  def flash_error(:question_pending), do: "Answer the agent's question first."
  def flash_error(other), do: "Could not steer (#{inspect(other)})."

  defp send_steer(task_id, text) do
    case Registry.lookup(@inbox, task_id) do
      [{pid, _}] ->
        send(pid, {:steer, text})
        {:ok, :injected}

      [] ->
        {:error, :not_running}
    end
  end

  defp question_pending?(task_id) do
    case KanbanBridge.get_task(task_id) do
      nil -> false
      task -> is_map(Board.pending_question(task))
    end
  end
end
