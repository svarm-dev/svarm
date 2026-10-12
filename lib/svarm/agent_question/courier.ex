defmodule Svarm.AgentQuestion.Courier do
  @moduledoc """
  One claim per task for a mid-run answer that was not injected yet.

  The claim is either `{:queued, body, deadline_at_ms}` or `:delivered`.
  A queued claim is sent only when `arrive/2` sees the same `request_id`
  before `deadline_at_ms`. An expired claim is absent. This process is the
  only writer.
  """

  use GenServer

  alias Svarm.Events

  @inbox Svarm.AgentQuestion.Inbox

  @type state :: {:queued, map(), integer()} | :delivered | :absent

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Inject `body` into the registered worker, or hold it until `deadline_at`.

  `deadline_at` is unix milliseconds. `nil` or a past value is not held.
  """
  @spec submit(String.t(), String.t(), map(), integer() | nil) ::
          {:ok, :injected | :queued} | {:error, :already_answered | :no_runner}
  def submit(task_id, request_id, body, deadline_at)
      when is_binary(task_id) and is_binary(request_id) and is_map(body) do
    GenServer.call(__MODULE__, {:submit, task_id, request_id, body, deadline_at})
  end

  @doc """
  Deliver a matching unexpired queued body to the registered worker.

  A different `request_id` drops the old claim and sends nothing. A second
  call for a delivered claim does not send again.
  """
  @spec arrive(String.t(), String.t()) :: :ok
  def arrive(task_id, request_id) when is_binary(task_id) and is_binary(request_id) do
    GenServer.call(__MODULE__, {:arrive, task_id, request_id})
  end

  @doc "Remove the claim for `task_id` and return the previous state."
  @spec drop(String.t()) :: state()
  def drop(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:drop, task_id})
  end

  @impl true
  def init(claims) when is_map(claims), do: {:ok, claims}

  @impl true
  def handle_call({:submit, task_id, request_id, body, deadline_at}, _from, claims) do
    {reply, claims} = take_slot(claims, task_id, request_id, body, deadline_at)
    {:reply, reply, claims}
  end

  def handle_call({:arrive, task_id, request_id}, _from, claims) do
    {:reply, :ok, deliver_on_arrive(claims, task_id, request_id)}
  end

  def handle_call({:drop, task_id}, _from, claims) do
    {claim, claims} = Map.pop(claims, task_id)
    {:reply, state_of(claim), claims}
  end

  @impl true
  def handle_info({:expire, task_id, request_id, deadline_at}, claims) do
    {:noreply, expire_if_due(claims, task_id, request_id, deadline_at)}
  end

  defp take_slot(claims, task_id, request_id, body, deadline_at) do
    claims = drop_expired(claims, task_id)

    case Map.get(claims, task_id) do
      %{request_id: ^request_id} ->
        {{:error, :already_answered}, claims}

      nil ->
        hold_or_inject(claims, task_id, request_id, body, deadline_at)

      _other ->
        claims
        |> Map.delete(task_id)
        |> hold_or_inject(task_id, request_id, body, deadline_at)
    end
  end

  defp hold_or_inject(claims, task_id, request_id, body, deadline_at) do
    case lookup(task_id) do
      {:ok, pid} ->
        send(pid, {:agent_question_reply, body})
        {{:ok, :injected}, put_claim(claims, task_id, request_id, :delivered)}

      {:error, :no_runner} ->
        if fresh?(deadline_at) do
          schedule_expiry(task_id, request_id, deadline_at)
          {{:ok, :queued}, put_claim(claims, task_id, request_id, {:queued, body, deadline_at})}
        else
          {{:error, :no_runner}, claims}
        end
    end
  end

  defp deliver_on_arrive(claims, task_id, request_id) do
    case Map.get(claims, task_id) do
      %{request_id: ^request_id, state: {:queued, body, deadline_at}} ->
        if fresh?(deadline_at) do
          send_queued(claims, task_id, request_id, body)
        else
          expire_if_due(claims, task_id, request_id, deadline_at)
        end

      %{request_id: ^request_id, state: :delivered} ->
        claims

      nil ->
        claims

      _other ->
        Map.delete(claims, task_id)
    end
  end

  defp send_queued(claims, task_id, request_id, body) do
    case lookup(task_id) do
      {:ok, pid} ->
        send(pid, {:agent_question_reply, body})
        put_claim(claims, task_id, request_id, :delivered)

      {:error, :no_runner} ->
        claims
    end
  end

  defp expire_if_due(claims, task_id, request_id, deadline_at) do
    case Map.get(claims, task_id) do
      %{request_id: ^request_id, state: {:queued, _body, ^deadline_at}} ->
        if fresh?(deadline_at) do
          schedule_expiry(task_id, request_id, deadline_at)
          claims
        else
          Events.broadcast_task_updated(%{id: task_id, reason: :agent_question_answer_expired})
          Map.delete(claims, task_id)
        end

      _ ->
        claims
    end
  end

  defp drop_expired(claims, task_id) do
    case Map.get(claims, task_id) do
      %{state: {:queued, _body, deadline_at}} ->
        if fresh?(deadline_at), do: claims, else: Map.delete(claims, task_id)

      _ ->
        claims
    end
  end

  defp put_claim(claims, task_id, request_id, state) do
    Map.put(claims, task_id, %{request_id: request_id, state: state})
  end

  defp state_of(nil), do: :absent
  defp state_of(%{state: state}), do: state

  defp fresh?(deadline_at) when is_integer(deadline_at) do
    deadline_at > System.system_time(:millisecond)
  end

  defp fresh?(_deadline_at), do: false

  defp schedule_expiry(task_id, request_id, deadline_at) do
    delay = max(deadline_at - System.system_time(:millisecond), 0)
    Process.send_after(self(), {:expire, task_id, request_id, deadline_at}, delay)
  end

  defp lookup(task_id) do
    case Registry.lookup(@inbox, task_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :no_runner}
    end
  end
end
