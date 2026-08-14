defmodule Svarm.AgentQuestion do
  @moduledoc """
  Mid-run human answers for PiRPC `extension_ui_request` dialogs.

  Web and tests call this module only — not `AgentRunner` or `Workspace`.
  The PiRPC worker registers in `Svarm.AgentQuestion.Inbox` while a dialog
  is pending; `answer/2` sends `{:agent_question_reply, payload}` and the
  worker writes `extension_ui_response` on the port.

  Dialog methods: `select`, `confirm`, `input`, `editor`.
  Fire-and-forget UI methods are ignored by the runner (no wait).

  Wait deadline is `min(pi request timeout, SVARM_AGENT_QUESTION_TIMEOUT_MS)`
  with a default of 15 minutes. On deadline the worker sends `cancelled: true`,
  clears wait, and continues the run. CLI inject is not supported.
  """

  alias Svarm.{Coordination, Events, KanbanBridge}

  @inbox Svarm.AgentQuestion.Inbox
  @default_timeout_ms 15 * 60_000
  @dialog_methods ~w(select confirm input editor)

  @type answer_attrs :: map()
  @type error :: :not_waiting | :no_runner | :invalid | :not_found

  @doc "Registry name for the waiting PiRPC worker (string task ids)."
  def inbox, do: @inbox

  @doc "Default / env-capped wait timeout in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    case System.get_env("SVARM_AGENT_QUESTION_TIMEOUT_MS") do
      nil ->
        @default_timeout_ms

      "" ->
        @default_timeout_ms

      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> @default_timeout_ms
        end
    end
  end

  @doc "True when `method` is a dialog that must be answered."
  @spec dialog_method?(term()) :: boolean()
  def dialog_method?(method) when is_binary(method), do: method in @dialog_methods
  def dialog_method?(_), do: false

  @doc """
  Monotonic deadline for a parked question.

  `cap_ms` is the Svärm cap (opts or `timeout_ms/0`). A pi `timeout` field
  is treated as milliseconds when `> 1000`, otherwise seconds.
  """
  @spec wait_deadline_ms(map(), pos_integer()) :: integer()
  def wait_deadline_ms(event, cap_ms) when is_map(event) and is_integer(cap_ms) and cap_ms > 0 do
    now = System.monotonic_time(:millisecond)
    now + min(cap_ms, request_timeout_ms(event) || cap_ms)
  end

  @doc """
  Persist a parked question and register the calling process as the inbox.

  Must be called from the PiRPC worker. Returns `{:ok, deadline_ms}`.
  Requires a non-empty prompt and request id (`id` / `request_id`).
  """
  @spec park(String.t(), map(), keyword()) :: {:ok, integer()} | {:error, :invalid}
  def park(task_id, event, opts \\ [])

  def park(task_id, event, opts) when is_binary(task_id) and is_map(event) do
    cap = Keyword.get(opts, :question_timeout_ms, timeout_ms())
    event = flatten_ui_event(event)

    case persist(task_id, attrs_from_event(event)) do
      {:ok, _payload} ->
        register(task_id)
        {:ok, wait_deadline_ms(event, cap)}

      {:error, :invalid} = err ->
        err
    end
  end

  @doc """
  Inject a human answer into the waiting PiRPC worker.

  `attrs` must include `value` (select/input/editor) or `confirmed` (confirm).
  """
  @spec answer(String.t(), answer_attrs()) :: {:ok, :injected} | {:error, error()}
  def answer(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    with {:ok, waiting} <- current_wait(task_id),
         {:ok, pid} <- lookup_runner(task_id),
         {:ok, body} <- build_response(waiting, attrs, cancelled: false) do
      send(pid, {:agent_question_reply, body})
      {:ok, :injected}
    end
  end

  @doc "Cancel a pending dialog (inject `cancelled: true` when a runner is live)."
  @spec cancel(String.t()) :: {:ok, :injected | :cleared} | {:error, error()}
  def cancel(task_id) when is_binary(task_id) do
    with {:ok, waiting} <- current_wait(task_id),
         {:ok, pid} <- lookup_runner(task_id),
         {:ok, body} <- build_response(waiting, %{}, cancelled: true) do
      send(pid, {:agent_question_reply, body})
      {:ok, :injected}
    else
      {:error, :no_runner} ->
        clear(task_id)
        {:ok, :cleared}

      {:error, _} = err ->
        err
    end
  end

  @doc "Operator-facing flash for `answer/2` / `cancel/1` errors."
  @spec flash_error(error()) :: String.t()
  def flash_error(:not_waiting), do: "No question is waiting on this task."
  def flash_error(:no_runner), do: "The agent run is no longer waiting for an answer."
  def flash_error(:invalid), do: "That answer does not match the question."
  def flash_error(:not_found), do: "Task not found."
  def flash_error(other), do: "Could not send answer (#{inspect(other)})."

  @doc """
  Drop durable wait + inbox registration without injecting.

  Called from the PiRPC worker on run end / abort so a dead session cannot
  leave a stuck chip. Safe when nothing is waiting.
  """
  @spec clear(String.t()) :: :ok
  def clear(task_id) when is_binary(task_id) do
    _ = KanbanBridge.clear_pending_question(task_id)
    _ = Coordination.upsert(task_id, %{wait_reason: nil, pending_question: nil})
    unregister()

    # Never send status — finish/after/watch_clear run after the tracker
    # already moved the card to review/failed. A partial in_progress payload
    # would yank BoardLive back and log a false status line.
    Events.broadcast_task_updated(%{
      id: task_id,
      wait_reason: nil,
      pending_question: nil,
      reason: :agent_question_cleared
    })

    :ok
  end

  @doc "Build the stdin JSON map for a dialog reply (tests + runner)."
  @spec build_response(map(), map(), keyword()) :: {:ok, map()} | {:error, :invalid}
  def build_response(waiting, attrs, opts \\ [])

  def build_response(waiting, attrs, opts) do
    id = request_id(waiting)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :invalid}

      Keyword.get(opts, :cancelled, false) ->
        {:ok, %{"type" => "extension_ui_response", "id" => id, "cancelled" => true}}

      true ->
        response_for_method(method(waiting), id, attrs)
    end
  end

  defp response_for_method("confirm", id, attrs) do
    case confirmed?(attrs) do
      nil -> {:error, :invalid}
      flag -> {:ok, %{"type" => "extension_ui_response", "id" => id, "confirmed" => flag}}
    end
  end

  defp response_for_method(method, id, attrs) when method in ["select", "input", "editor"] do
    case value(attrs) do
      v when is_binary(v) ->
        {:ok, %{"type" => "extension_ui_response", "id" => id, "value" => v}}

      _ ->
        {:error, :invalid}
    end
  end

  defp response_for_method(_, id, attrs) do
    case value(attrs) do
      v when is_binary(v) ->
        {:ok, %{"type" => "extension_ui_response", "id" => id, "value" => v}}

      _ ->
        {:error, :invalid}
    end
  end

  defp persist(task_id, attrs) do
    case normalize_payload(attrs) do
      {:ok, payload} ->
        _ = KanbanBridge.put_pending_question(task_id, attrs)

        _ =
          Coordination.upsert(task_id, %{wait_reason: "agent_question", pending_question: payload})

        Events.broadcast_task_updated(%{
          id: task_id,
          status: "in_progress",
          wait_reason: "agent_question",
          pending_question: payload,
          reason: :agent_question
        })

        {:ok, payload}

      err ->
        err
    end
  end

  defp normalize_payload(attrs) when is_map(attrs) do
    prompt = map_get(attrs, :prompt)
    request_id = map_get(attrs, :request_id)

    if present?(prompt) and present?(request_id) do
      payload =
        %{
          "reason" => "agent_question",
          "prompt" => prompt,
          "request_id" => request_id,
          "method" => map_get(attrs, :method),
          "options" => map_get(attrs, :options),
          "asked_at" => map_get(attrs, :asked_at) || System.system_time(:second)
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

      {:ok, payload}
    else
      {:error, :invalid}
    end
  end

  defp attrs_from_event(event) when is_map(event) do
    method = event["method"] || event["requestType"] || event["request_type"]
    prompt = event["message"] || event["title"] || event["placeholder"] || "Agent needs input"

    %{
      prompt: prompt,
      request_id: event["id"] || event["request_id"],
      method: method,
      options: event["options"],
      asked_at: System.system_time(:second)
    }
  end

  defp current_wait(task_id) do
    cond do
      match?(%{"prompt" => _}, payload_from_task(task_id)) ->
        {:ok, payload_from_task(task_id)}

      match?(%{"prompt" => _}, payload_from_coord(task_id)) ->
        {:ok, payload_from_coord(task_id)}

      true ->
        {:error, :not_waiting}
    end
  end

  defp payload_from_task(task_id) do
    case KanbanBridge.get_task(task_id) do
      %{pending_question: q} when is_map(q) -> q
      _ -> nil
    end
  end

  defp payload_from_coord(task_id) do
    case Coordination.get(task_id) do
      %{pending_question: q} when is_map(q) -> q
      _ -> nil
    end
  end

  defp lookup_runner(task_id) do
    case Registry.lookup(@inbox, task_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :no_runner}
    end
  end

  defp register(task_id) do
    unregister()

    case Registry.register(@inbox, task_id, :waiting) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  defp unregister do
    # Only the registered process may unregister; a no-op when called elsewhere.
    Registry.keys(@inbox, self())
    |> Enum.each(&Registry.unregister(@inbox, &1))
  end

  defp flatten_ui_event(%{"params" => params} = event) when is_map(params) do
    Map.merge(params, event)
  end

  defp flatten_ui_event(event), do: event

  defp request_timeout_ms(event) do
    case map_get(event, :timeout) do
      n when is_integer(n) and n > 1000 -> n
      n when is_integer(n) and n > 0 -> n * 1000
      _ -> nil
    end
  end

  defp request_id(waiting), do: map_get(waiting, :request_id) || map_get(waiting, :id)
  defp method(waiting), do: map_get(waiting, :method) || "input"

  defp value(attrs) do
    case map_get(attrs, :value) do
      v when is_binary(v) ->
        if String.trim(v) == "", do: nil, else: v

      _ ->
        nil
    end
  end

  defp confirmed?(attrs) do
    case map_get(attrs, :confirmed) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      "yes" -> true
      "no" -> false
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
