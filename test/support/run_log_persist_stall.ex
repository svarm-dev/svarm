defmodule Svarm.RunLog.Buffer.Stall do
  @moduledoc false
  # Test-only gate: when registered, Buffer persist tasks wait on `:await`.
  use GenServer

  def start_link do
    # Unlinked: the test process exiting would otherwise kill Stall before on_exit.
    GenServer.start(__MODULE__, self(), name: __MODULE__)
  end

  def release do
    GenServer.call(__MODULE__, :release)
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @impl true
  def init(test_pid) do
    {:ok, %{test_pid: test_pid, waiters: [], open: false}}
  end

  @impl true
  def handle_call(:await, _from, %{open: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await, from, state) do
    send(state.test_pid, {:persist_await, from})
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:release, _from, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    {:reply, :ok, %{state | waiters: [], open: true}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    :ok
  end
end
