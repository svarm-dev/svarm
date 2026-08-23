defmodule Svarm.RunLog.Buffer do
  @moduledoc """
  Coalescing write-behind buffer for `Svarm.RunLog`.

  Agent stream chunks are stored in memory (and a public ETS table) so
  `append/3` can return without waiting for SQLite. A background persist
  task flushes with SQL `content || ?` — not a full-row read-modify-write.
  Pending-bytes back-pressure keeps the queue bounded when the database is
  slow.

  Flush triggers: size threshold, periodic timer, explicit `flush/1`,
  or process terminate.
  """
  use GenServer

  alias Svarm.RunLog

  @name __MODULE__
  @table __MODULE__
  # Optional test process: when registered, persist waits on `GenServer.call(pid, :await)`.
  @stall_name Svarm.RunLog.Buffer.Stall
  # Coalesce small stream deltas; still flush promptly for board durability.
  @flush_bytes 4_096
  @flush_interval_ms 50
  @max_pending_bytes 1_048_576
  @resume_pending_bytes div(1_048_576, 2)

  # —— Public API ——

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{table: @table}, name: name)
  end

  @doc """
  Enqueue a redacted chunk for `task_id`.

  Returns once the chunk is visible to `pending/1` / `RunLog.get/1`. Does
  not wait for SQLite. When pending bytes exceed the cap, the call waits
  until persist drains (bounded back-pressure).
  """
  def append(task_id, chunk, server \\ @name)

  def append(task_id, "", _server) when is_binary(task_id), do: :ok

  def append(task_id, chunk, server)
      when is_binary(task_id) and is_binary(chunk) do
    GenServer.call(server, {:append, task_id, chunk})
  end

  @doc "Pending (not yet ACKed durable) content for a task, or empty string."
  def pending(task_id, _server \\ @name) when is_binary(task_id) do
    case :ets.whereis(@table) do
      :undefined ->
        ""

      _tid ->
        case :ets.lookup(@table, task_id) do
          [{^task_id, pending}] -> pending
          [] -> ""
        end
    end
  end

  @doc "Force-flush one task's buffer to SQLite."
  def flush(task_id, server \\ @name) when is_binary(task_id) do
    GenServer.call(server, {:flush, task_id})
  end

  @doc "Force-flush every pending buffer."
  def flush_all(server \\ @name) do
    GenServer.call(server, :flush_all)
  end

  # —— GenServer ——

  @impl true
  def init(opts) do
    table = Map.get(opts, :table, @table)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

      _tid ->
        :ok
    end

    {:ok,
     %{
       table: table,
       buffers: %{},
       pending_bytes: 0,
       inflight: nil,
       append_waiters: :queue.new(),
       flush_waiters: %{},
       flush_all_waiters: [],
       timer: nil
     }}
  end

  @impl true
  def handle_call({:append, task_id, chunk}, from, state) do
    state =
      state
      |> enqueue(task_id, chunk)
      |> maybe_persist_task(task_id)
      |> ensure_timer()

    if state.pending_bytes >= @max_pending_bytes do
      {:noreply, park_append(state, from)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:flush, task_id}, from, state) do
    if idle_task?(state, task_id) do
      {:reply, :ok, state}
    else
      state =
        state
        |> add_flush_waiter(task_id, from)
        |> maybe_persist_task(task_id)
        |> ensure_timer()

      {:noreply, state}
    end
  end

  def handle_call(:flush_all, from, state) do
    if idle_all?(state) do
      {:reply, :ok, state}
    else
      state =
        state
        |> Map.update!(:flush_all_waiters, &[from | &1])
        |> persist_any()
        |> ensure_timer()

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush_tick, state) do
    state =
      %{state | timer: nil}
      |> persist_any()
      |> ensure_timer()

    {:noreply, state}
  end

  def handle_info({:persisted, task_id, n}, state) do
    {:noreply, finish_persist(state, task_id, n)}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    # `{:persisted, ...}` is the ACK; :normal DOWN is ignored (may race).
    _ = ref
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.inflight do
      {^ref, task_id, _n} ->
        # Persist task crashed before ACK — keep pending and retry.
        state = %{state | inflight: nil}
        {:noreply, state |> maybe_persist_task(task_id) |> ensure_timer()}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = await_inflight(state)
    sync_persist_all(state)
    :ok
  end

  # —— Internals ——

  defp enqueue(state, task_id, chunk) do
    {iodata, size} = Map.get(state.buffers, task_id, {[], 0})
    size = size + byte_size(chunk)
    iodata = [iodata, chunk]
    pending = IO.iodata_to_binary(iodata)
    :ets.insert(state.table, {task_id, pending})

    %{
      state
      | buffers: Map.put(state.buffers, task_id, {iodata, size}),
        pending_bytes: state.pending_bytes + byte_size(chunk)
    }
  end

  defp idle_task?(state, task_id) do
    not Map.has_key?(state.buffers, task_id) and not inflight_task?(state, task_id)
  end

  defp idle_all?(state) do
    state.buffers == %{} and state.inflight == nil
  end

  defp inflight_task?(state, task_id) do
    match?({_ref, ^task_id, _n}, state.inflight)
  end

  defp maybe_persist_task(state, task_id) do
    cond do
      state.inflight != nil ->
        state

      flush_requested?(state, task_id) ->
        start_persist(state, task_id)

      task_size(state, task_id) >= @flush_bytes ->
        start_persist(state, task_id)

      true ->
        state
    end
  end

  defp persist_any(state), do: persist_first(state, Map.keys(state.buffers))

  defp kick_after_ack(state) do
    cond do
      state.flush_all_waiters != [] ->
        persist_first(state, Map.keys(state.buffers))

      map_size(state.flush_waiters) > 0 ->
        persist_first(state, Map.keys(state.flush_waiters))

      true ->
        oversized =
          for {task_id, {_io, size}} <- state.buffers, size >= @flush_bytes, do: task_id

        persist_first(state, oversized)
    end
  end

  defp persist_first(%{inflight: inf} = state, _task_ids) when inf != nil, do: state

  defp persist_first(state, task_ids) do
    Enum.find_value(task_ids, state, fn task_id ->
      if task_size(state, task_id) > 0 do
        start_persist(state, task_id)
      end
    end)
  end

  defp flush_requested?(state, task_id) do
    state.flush_all_waiters != [] or Map.has_key?(state.flush_waiters, task_id)
  end

  defp task_size(state, task_id) do
    case Map.get(state.buffers, task_id) do
      {_, size} -> size
      nil -> 0
    end
  end

  defp start_persist(state, task_id) do
    case Map.get(state.buffers, task_id) do
      {iodata, size} when size > 0 ->
        chunk = IO.iodata_to_binary(iodata)
        parent = self()

        {:ok, pid} =
          Task.start(fn ->
            await_stall()
            RunLog.persist_append(task_id, chunk)
            send(parent, {:persisted, task_id, size})
          end)

        ref = Process.monitor(pid)
        %{state | inflight: {ref, task_id, size}}

      _ ->
        state
    end
  end

  defp finish_persist(state, task_id, n) do
    state =
      case state.inflight do
        {ref, ^task_id, ^n} ->
          Process.demonitor(ref, [:flush])
          %{state | inflight: nil}

        _ ->
          %{state | inflight: nil}
      end

    state
    |> drop_prefix(task_id, n)
    |> reply_append_waiters()
    |> reply_flush_waiters(task_id)
    |> kick_after_ack()
    |> ensure_timer()
  end

  defp drop_prefix(state, task_id, n) do
    case Map.get(state.buffers, task_id) do
      nil ->
        state

      {iodata, size} ->
        rest_size = size - n
        pending_bytes = max(state.pending_bytes - n, 0)

        if rest_size <= 0 do
          :ets.delete(state.table, task_id)

          %{
            state
            | buffers: Map.delete(state.buffers, task_id),
              pending_bytes: pending_bytes
          }
        else
          pending =
            iodata
            |> IO.iodata_to_binary()
            |> binary_part(n, rest_size)

          :ets.insert(state.table, {task_id, pending})

          %{
            state
            | buffers: Map.put(state.buffers, task_id, {[pending], rest_size}),
              pending_bytes: pending_bytes
          }
        end
    end
  end

  defp park_append(state, from) do
    %{state | append_waiters: :queue.in(from, state.append_waiters)}
  end

  defp reply_append_waiters(state) when state.pending_bytes > @resume_pending_bytes do
    state
  end

  defp reply_append_waiters(state) do
    reply_queue(state.append_waiters)
    %{state | append_waiters: :queue.new()}
  end

  defp add_flush_waiter(state, task_id, from) do
    waiters = Map.get(state.flush_waiters, task_id, [])
    %{state | flush_waiters: Map.put(state.flush_waiters, task_id, [from | waiters])}
  end

  defp reply_flush_waiters(state, task_id) do
    state =
      if idle_task?(state, task_id) do
        case Map.pop(state.flush_waiters, task_id) do
          {nil, _} ->
            state

          {waiters, flush_waiters} ->
            Enum.each(waiters, &GenServer.reply(&1, :ok))
            %{state | flush_waiters: flush_waiters}
        end
      else
        state
      end

    if idle_all?(state) and state.flush_all_waiters != [] do
      Enum.each(state.flush_all_waiters, &GenServer.reply(&1, :ok))
      %{state | flush_all_waiters: []}
    else
      state
    end
  end

  defp reply_queue(queue) do
    case :queue.out(queue) do
      {:empty, _} ->
        :ok

      {{:value, from}, rest} ->
        GenServer.reply(from, :ok)
        reply_queue(rest)
    end
  end

  defp ensure_timer(%{timer: nil} = state) do
    if state.buffers == %{} and state.inflight == nil do
      state
    else
      ref = Process.send_after(self(), :flush_tick, @flush_interval_ms)
      %{state | timer: ref}
    end
  end

  defp ensure_timer(state), do: state

  defp await_stall do
    case Process.whereis(@stall_name) do
      nil -> :ok
      pid -> GenServer.call(pid, :await, :infinity)
    end
  end

  defp await_inflight(%{inflight: nil} = state), do: state

  defp await_inflight(%{inflight: {ref, task_id, n}} = state) do
    receive do
      {:persisted, ^task_id, ^n} ->
        Process.demonitor(ref, [:flush])
        drop_prefix(%{state | inflight: nil}, task_id, n)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        %{state | inflight: nil}
    after
      5_000 ->
        %{state | inflight: nil}
    end
  end

  defp sync_persist_all(state) do
    Enum.each(state.buffers, fn {task_id, {iodata, size}} ->
      if size > 0 do
        RunLog.persist_append(task_id, IO.iodata_to_binary(iodata))
      end
    end)
  end
end
