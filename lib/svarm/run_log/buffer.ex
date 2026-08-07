defmodule Svarm.RunLog.Buffer do
  @moduledoc """
  Coalescing write-behind buffer for `Svarm.RunLog`.

  Agent stream chunks are accumulated in memory and flushed to SQLite as a
  single SQL `content || ?` append — not a full-row read-modify-write per
  delta. Flush triggers: size threshold, periodic timer, explicit `flush/1`,
  or process terminate.
  """
  use GenServer

  alias Svarm.RunLog

  @name __MODULE__
  # Coalesce small stream deltas; still flush promptly for board durability.
  @flush_bytes 4_096
  @flush_interval_ms 50

  # —— Public API ——

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Enqueue a redacted chunk for task_id. Synchronous so get sees it."
  def append(task_id, chunk, server \\ @name)
      when is_binary(task_id) and is_binary(chunk) do
    GenServer.call(server, {:append, task_id, chunk})
  end

  @doc "Pending (not yet durable) content for a task, or empty string."
  def pending(task_id, server \\ @name) when is_binary(task_id) do
    GenServer.call(server, {:pending, task_id})
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
  def init(_opts) do
    {:ok, %{buffers: %{}, timer: nil}}
  end

  @impl true
  def handle_call({:append, task_id, chunk}, _from, state) do
    {iodata, size} = Map.get(state.buffers, task_id, {[], 0})
    size = size + byte_size(chunk)
    iodata = [iodata, chunk]
    buffers = Map.put(state.buffers, task_id, {iodata, size})

    state = %{state | buffers: buffers} |> ensure_timer()

    state =
      if size >= @flush_bytes do
        do_flush_task(state, task_id)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:pending, task_id}, _from, state) do
    {:reply, pending_binary(state, task_id), state}
  end

  def handle_call({:flush, task_id}, _from, state) do
    {:reply, :ok, do_flush_task(state, task_id)}
  end

  def handle_call(:flush_all, _from, state) do
    {:reply, :ok, do_flush_all(state)}
  end

  @impl true
  def handle_info(:flush_tick, state) do
    state = %{state | timer: nil} |> do_flush_all()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = do_flush_all(state)
    :ok
  end

  # —— Internals ——

  defp pending_binary(state, task_id) do
    case Map.get(state.buffers, task_id) do
      nil -> ""
      {iodata, _} -> IO.iodata_to_binary(iodata)
    end
  end

  defp ensure_timer(%{timer: nil} = state) do
    ref = Process.send_after(self(), :flush_tick, @flush_interval_ms)
    %{state | timer: ref}
  end

  defp ensure_timer(state), do: state

  defp do_flush_task(state, task_id) do
    case Map.pop(state.buffers, task_id) do
      {nil, _} ->
        state

      {{iodata, _size}, buffers} ->
        chunk = IO.iodata_to_binary(iodata)

        if chunk != "" do
          RunLog.persist_append(task_id, chunk)
        end

        %{state | buffers: buffers}
    end
  end

  defp do_flush_all(state) do
    Enum.reduce(Map.keys(state.buffers), state, fn task_id, acc ->
      do_flush_task(acc, task_id)
    end)
  end
end
