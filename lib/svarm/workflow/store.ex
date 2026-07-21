defmodule Svarm.Workflow.Store do
  @moduledoc """
  Holds the current workflow definition; reloads on `WORKFLOW.md` changes (Symphony §6.2).
  """
  use GenServer

  alias Svarm.Workflow

  defstruct [:workflow, :path, :subscribers]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get, do: GenServer.call(__MODULE__, :get)
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> default_path() end)
    state = %__MODULE__{path: path, subscribers: MapSet.new()}

    send(self(), :load)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, %{workflow: wf} = state) do
    {:reply, wf, state}
  end

  def handle_call(:reload, _from, state) do
    {:reply, :ok, do_load(state)}
  end

  @impl true
  def handle_info(:load, state), do: {:noreply, do_load(state)}

  def handle_info({:workflow_changed, _}, state), do: {:noreply, do_load(state)}

  defp do_load(%{path: path} = state) do
    case Workflow.load(path) do
      {:ok, wf} ->
        notify_subscribers(wf)
        %{state | workflow: wf}

      {:error, reason} ->
        require Logger
        Logger.warning("WORKFLOW.md load failed (#{path}): #{inspect(reason)}")
        %{state | workflow: nil}
    end
  end

  defp notify_subscribers(wf) do
    if Process.whereis(Svarm.Orchestrator) do
      send(Svarm.Orchestrator, {:workflow_reloaded, wf})
    end
  end

  defp default_path do
    case Workflow.discover() do
      {:ok, %Workflow{path: p}} -> p
      _ -> Path.join(:code.priv_dir(:svarm), "workflow_template.md")
    end
  end
end
