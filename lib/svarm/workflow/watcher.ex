defmodule Svarm.Workflow.Watcher do
  @moduledoc "Watches `WORKFLOW.md` and tells Workflow.Store to reload."
  use GenServer

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    dir = Path.dirname(path)
    file = Path.basename(path)

    {:ok, pid} = FileSystem.Worker.start_link(dirs: [dir])
    FileSystem.subscribe(pid)

    {:ok, %{worker: pid, path: path, file: file}}
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
