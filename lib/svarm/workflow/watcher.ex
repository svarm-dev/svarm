defmodule Svarm.Workflow.Watcher do
  @moduledoc """
  Watches `WORKFLOW.md` and tells Workflow.Store to reload.

  If no filesystem backend is available (common in CI without `inotify-tools`),
  the process is ignored and the app boots without live reload.
  """
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    dir = Path.dirname(path)
    file = Path.basename(path)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        {:ok, %{worker: pid, path: path, file: file}}

      :ignore ->
        Logger.info("workflow watcher: no file_system backend; live reload disabled")
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _}}, state) do
    if Path.basename(path) == state.file do
      send(Svarm.Workflow.Store, {:workflow_changed, path})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
