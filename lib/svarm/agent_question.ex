defmodule Svarm.AgentQuestion do
  @moduledoc """
  Mid-run human answers for PiRPC `extension_ui_request` dialogs.

  Web and tests call this module only, not `AgentRunner` or `Workspace`.
  The PiRPC worker registers in `Svarm.AgentQuestion.Inbox` while a dialog
  is pending. `answer/2` sends `{:agent_question_reply, payload}` when that
  worker is registered. If the question is parked and no worker is
  registered, a matching answer is held until `park/3` delivers it once.
  The worker writes `extension_ui_response` on the port.

  Dialog methods: `select`, `confirm`, `input`, `editor`.
  Fire-and-forget UI methods are ignored by the runner (no wait).

  Wait deadline is `min(pi request timeout, SVARM_AGENT_QUESTION_TIMEOUT_MS)`
  with a default of 15 minutes. On deadline the worker sends `cancelled: true`,
  clears wait, and continues the run. CLI inject is not supported.
  """

  alias Svarm.AgentQuestion.Courier
  alias Svarm.{Coordination, Events, KanbanBridge}

  @inbox Svarm.AgentQuestion.Inbox
  @default_timeout_ms 15 * 60_000
  @dialog_methods ~w(select confirm input editor)

  @type answer_attrs :: map()
  @type error :: :not_waiting | :no_runner | :invalid | :not_found | :already_answered

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
    System.monotonic_time(:millisecond) + wait_duration_ms(event, cap_ms)
  end

  @doc """
  Persist a parked question and register the calling process as the inbox.

  Must be called from the PiRPC worker. Returns `{:ok, deadline_ms}` where
  `deadline_ms` is monotonic, using the same duration as `wait_deadline_ms/2`.
  Stores `deadline_at` (unix milliseconds) on the question payload. Delivers
  a held answer for the same request id when that deadline is still ahead.
  Requires a non-empty prompt and request id (`id` / `request_id`).
  """
  @spec park(String.t(), map(), keyword()) :: {:ok, integer()} | {:error, :invalid}
  def park(task_id, event, opts \\ [])

  def park(task_id, event, opts) when is_binary(task_id) and is_map(event) do
    cap = Keyword.get(opts, :question_timeout_ms, timeout_ms())
    event = flatten_ui_event(event)
    duration = wait_duration_ms(event, cap)

    attrs =
      event
      |> attrs_from_event()
      |> Map.put(:deadline_at, System.system_time(:millisecond) + duration)

    case persist(task_id, attrs) do
      {:ok, payload} ->
        register(task_id)
        Courier.arrive(task_id, request_id(payload))
        {:ok, System.monotonic_time(:millisecond) + duration}

      {:error, :invalid} = err ->
        err
    end
  end

  @doc """
  Inject or hold a human answer for the parked question.

  `attrs` must include `value` (select/input/editor) or `confirmed` (confirm).
  Optional `request_id` must match the parked question when present.

  Returns `{:ok, :injected}` after the reply is sent, then clears the wait.
  A second click is `:not_waiting`. Returns `{:ok, :queued}` when the
  question is parked, the request id matches, the deadline is still ahead,
  and no worker is registered. Does not clear the row in that case.

  Returns `{:error, :not_waiting}` when nothing is parked,
  `{:error, :invalid}` when the body or request id does not match,
  `{:error, :already_answered}` when this request id already has a held or
  delivered claim, and `{:error, :no_runner}` when no worker is registered
  and the deadline is missing or already past.
  """
  @spec answer(String.t(), answer_attrs()) :: {:ok, :injected | :queued} | {:error, error()}
  def answer(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    with {:ok, waiting} <- current_wait(task_id),
         :ok <- match_request(waiting, attrs),
         {:ok, body} <- build_response(waiting, attrs, cancelled: false),
         {:ok, outcome} <-
           Courier.submit(task_id, request_id(waiting), body, payload_deadline(waiting)) do
      finish_answer(task_id, outcome)
    end
  end

  @doc """
  Cancel a pending dialog.

  Drops any held answer first. If that answer was already delivered, clears
  the wait and does not send `cancelled: true`. Otherwise injects
  `cancelled: true` when a runner is live, or clears on `:no_runner`.
  """
  @spec cancel(String.t()) :: {:ok, :injected | :cleared} | {:error, error()}
  def cancel(task_id) when is_binary(task_id) do
    case Courier.drop(task_id) do
      :delivered ->
        clear(task_id)
        {:ok, :cleared}

      _other ->
        cancel_pending(task_id)
    end
  end

  @doc "Operator-facing flash for `answer/2` / `cancel/1` errors."
  @spec flash_error(error()) :: String.t()
  def flash_error(:not_waiting), do: "No question is waiting on this task."
  def flash_error(:no_runner), do: "The agent run is no longer waiting for an answer."
  def flash_error(:invalid), do: "That answer does not match the question."
  def flash_error(:not_found), do: "Task not found."
  def flash_error(:already_answered), do: "An answer is already queued for this question."
  def flash_error(other), do: "Could not send answer (#{inspect(other)})."

  @doc """
  Drop the held answer, durable wait, and inbox registration without injecting.

  Called from the PiRPC worker on run end / abort so a dead session cannot
  leave a stuck chip. Safe when nothing is waiting. A down courier is ignored
  so an `after` block still finishes.
  """
  @spec clear(String.t()) :: :ok
  def clear(task_id) when is_binary(task_id) do
    try do
      Courier.drop(task_id)
    catch
      :exit, _reason -> :ok
    end

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
          "asked_at" => map_get(attrs, :asked_at) || System.system_time(:second),
          "deadline_at" => integer_deadline(map_get(attrs, :deadline_at))
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

  defp wait_duration_ms(event, cap_ms) do
    min(cap_ms, request_timeout_ms(event) || cap_ms)
  end

  defp finish_answer(task_id, :injected) do
    clear(task_id)
    {:ok, :injected}
  end

  defp finish_answer(_task_id, :queued), do: {:ok, :queued}

  defp cancel_pending(task_id) do
    with {:ok, waiting} <- current_wait(task_id),
         {:ok, pid} <- lookup_runner(task_id),
         {:ok, body} <- build_response(waiting, %{}, cancelled: true) do
      send(pid, {:agent_question_reply, body})
      clear(task_id)
      {:ok, :injected}
    else
      {:error, :no_runner} ->
        clear(task_id)
        {:ok, :cleared}

      {:error, _} = err ->
        err
    end
  end

  defp payload_deadline(waiting) do
    integer_deadline(map_get(waiting, :deadline_at))
  end

  defp integer_deadline(value) when is_integer(value), do: value
  defp integer_deadline(_value), do: nil

  defp request_timeout_ms(event) do
    case map_get(event, :timeout) do
      n when is_integer(n) and n > 1000 -> n
      n when is_integer(n) and n > 0 -> n * 1000
      _ -> nil
    end
  end

  defp request_id(waiting), do: map_get(waiting, :request_id) || map_get(waiting, :id)
  defp method(waiting), do: map_get(waiting, :method) || "input"

  defp match_request(waiting, attrs) do
    given = map_get(attrs, :request_id)

    cond do
      not present?(given) -> :ok
      given == request_id(waiting) -> :ok
      true -> {:error, :invalid}
    end
  end

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
