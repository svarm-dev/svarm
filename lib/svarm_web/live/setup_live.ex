defmodule SvarmWeb.SetupLive do
  @moduledoc """
  In-app setup: OpenRouter, GitHub tracker PAT, default agent model, Apply reload.
  """
  use SvarmWeb, :live_view

  alias Svarm.{Orchestrator, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_setup(socket)}
  end

  @impl true
  def handle_event("save_provider", %{"provider" => params}, socket) do
    case Settings.put_provider(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider saved")
         |> assign_setup()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save provider")}
    end
  end

  def handle_event("test_provider", _params, socket) do
    case Settings.test_provider() do
      {:ok, count} ->
        {:noreply, put_flash(socket, :info, "OpenRouter OK — #{count} models")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "OpenRouter test failed: #{reason}")}
    end
  end

  def handle_event("save_tracker", %{"tracker" => params}, socket) do
    params =
      params
      |> Map.update("required_labels", [], fn
        labels when is_binary(labels) ->
          labels
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        other ->
          other
      end)

    case Settings.put_tracker(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tracker saved")
         |> assign_setup()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save tracker")}
    end
  end

  def handle_event("test_tracker", _params, socket) do
    case Settings.test_tracker() do
      {:ok, :local} ->
        {:noreply, put_flash(socket, :info, "Local tracker ready")}

      {:ok, count} when is_integer(count) ->
        {:noreply, put_flash(socket, :info, "GitHub OK — #{count} open issues")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Tracker test failed: #{reason}")}
    end
  end

  def handle_event("save_agent", %{"agent" => params}, socket) do
    case Settings.put_default_agent(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default agent saved")
         |> assign_setup()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save agent")}
    end
  end

  def handle_event("apply", _params, socket) do
    case Orchestrator.reload_config() do
      {:ok, summary} ->
        msg =
          "Applied — #{summary.agent_count} agents, tracker #{summary.tracker_kind}"

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> assign_setup()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Apply failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-2xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Setup</h1>
            <p class="mt-1 text-sm opacity-70">
              Connect OpenRouter and GitHub from the running app. File/env config still works
              when these are empty.
            </p>
          </div>
          <a href={~p"/board"} class="btn btn-sm btn-ghost">Board</a>
        </div>

        <.status_strip status={@status} />

        <.provider_card form={@provider_form} provider={@provider} />
        <.tracker_card form={@tracker_form} tracker={@tracker} status={@status} />
        <.agent_card form={@agent_form} agent={@agent} />

        <div class="flex flex-wrap items-center gap-3 pt-2">
          <button type="button" phx-click="apply" class="btn btn-primary">
            Apply configuration
          </button>
          <p class="text-xs opacity-60">
            Reloads agents and tracker in the orchestrator without restarting the node.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## components

  attr :status, :map, required: true

  defp status_strip(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2" aria-label="Setup readiness">
      <.chip ok?={@status.provider_configured?} label="Provider" />
      <.chip
        ok?={@status.tracker_ready?}
        label={"Tracker (#{@status.tracker_source})"}
      />
      <.chip ok?={@status.agent_count > 0} label={"Agents (#{@status.agent_count})"} />
      <.chip ok?={@status.setup_complete?} label="Ready" />
    </div>
    """
  end

  attr :ok?, :boolean, required: true
  attr :label, :string, required: true

  defp chip(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm font-mono",
      if(@ok?, do: "badge-success", else: "badge-ghost opacity-70")
    ]}>
      {if @ok?, do: "✓", else: "○"} {@label}
    </span>
    """
  end

  attr :form, :map, required: true
  attr :provider, :map, required: true

  defp provider_card(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-200/50 p-4 space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="font-semibold">OpenRouter</h2>
        <button type="button" phx-click="test_provider" class="btn btn-xs btn-outline">
          Test connection
        </button>
      </div>
      <.form for={@form} id="provider-form" phx-submit="save_provider" class="space-y-3">
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">API key</span>
          <input
            type="password"
            name="provider[api_key]"
            class="input input-bordered input-sm w-full font-mono"
            placeholder={
              if @provider[:api_key_set?], do: "•••• set — leave blank to keep", else: "sk-or-…"
            }
            autocomplete="off"
          />
        </label>
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">Default model (optional)</span>
          <input
            type="text"
            name="provider[default_model]"
            value={@provider[:default_model] || ""}
            class="input input-bordered input-sm w-full font-mono"
            placeholder="openrouter/free"
          />
        </label>
        <button type="submit" class="btn btn-sm btn-primary">Save provider</button>
      </.form>
    </section>
    """
  end

  attr :form, :map, required: true
  attr :tracker, :map, required: true
  attr :status, :map, required: true

  defp tracker_card(assigns) do
    kind = to_string(assigns.tracker[:kind] || "local")

    labels =
      case assigns.tracker[:required_labels] do
        list when is_list(list) -> list
        bin when is_binary(bin) -> [bin]
        _ -> []
      end

    labels_str = Enum.join(labels, ", ")
    assigns = assign(assigns, kind: kind, labels_str: labels_str)

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-200/50 p-4 space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="font-semibold">Tracker</h2>
        <button type="button" phx-click="test_tracker" class="btn btn-xs btn-outline">
          Test connection
        </button>
      </div>
      <p class="text-xs opacity-60">
        Source: <span class="font-mono">{@status.tracker_source}</span>
        · local needs nothing; GitHub needs owner/repo + PAT
      </p>
      <.form for={@form} id="tracker-form" phx-submit="save_tracker" class="space-y-3">
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">Kind</span>
          <select name="tracker[kind]" class="select select-bordered select-sm w-full">
            <option value="local" selected={@kind == "local"}>local</option>
            <option value="github" selected={@kind == "github"}>github</option>
          </select>
        </label>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <label class="form-control w-full">
            <span class="label-text text-xs opacity-70">Owner</span>
            <input
              type="text"
              name="tracker[owner]"
              value={@tracker[:owner] || ""}
              class="input input-bordered input-sm w-full font-mono"
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text text-xs opacity-70">Repo</span>
            <input
              type="text"
              name="tracker[repo]"
              value={@tracker[:repo] || ""}
              class="input input-bordered input-sm w-full font-mono"
            />
          </label>
        </div>
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">GitHub PAT</span>
          <input
            type="password"
            name="tracker[api_key]"
            class="input input-bordered input-sm w-full font-mono"
            placeholder={
              if @tracker[:api_key_set?], do: "•••• set — leave blank to keep", else: "ghp_…"
            }
            autocomplete="off"
          />
        </label>
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">Required labels (comma-separated)</span>
          <input
            type="text"
            name="tracker[required_labels]"
            value={@labels_str}
            class="input input-bordered input-sm w-full font-mono"
            placeholder="ai-task"
          />
        </label>
        <input type="hidden" name="tracker[auth]" value="token" />
        <button type="submit" class="btn btn-sm btn-primary">Save tracker</button>
      </.form>
    </section>
    """
  end

  attr :form, :map, required: true
  attr :agent, :map, required: true

  defp agent_card(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-200/50 p-4 space-y-3">
      <h2 class="font-semibold">Default agent</h2>
      <p class="text-xs opacity-60">
        Overrides <code class="font-mono">agents.toml</code>
        for the <code class="font-mono">default</code>
        agent only.
      </p>
      <.form for={@form} id="agent-form" phx-submit="save_agent" class="space-y-3">
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">Provider</span>
          <input
            type="text"
            name="agent[provider]"
            value={@agent["provider"] || "openrouter"}
            class="input input-bordered input-sm w-full font-mono"
          />
        </label>
        <label class="form-control w-full">
          <span class="label-text text-xs opacity-70">Model</span>
          <input
            type="text"
            name="agent[model]"
            value={@agent["model"] || ""}
            class="input input-bordered input-sm w-full font-mono"
            placeholder="openrouter/free"
          />
        </label>
        <button type="submit" class="btn btn-sm btn-primary">Save agent</button>
      </.form>
    </section>
    """
  end

  defp assign_setup(socket) do
    provider =
      case Settings.get_section("provider.openrouter") do
        {:ok, m} -> m
        :error -> %{}
      end

    tracker =
      case Settings.get_section("tracker") do
        {:ok, m} -> m
        :error -> %{"kind" => "local"}
      end

    agents =
      case Settings.get_section("agents") do
        {:ok, m} -> m
        :error -> %{}
      end

    agent = agents["default"] || %{}
    status = Settings.status()

    socket
    |> assign(:status, status)
    |> assign(:provider, provider)
    |> assign(:tracker, tracker)
    |> assign(:agent, agent)
    |> assign(:provider_form, to_form(%{}, as: :provider))
    |> assign(:tracker_form, to_form(%{}, as: :tracker))
    |> assign(:agent_form, to_form(%{}, as: :agent))
  end
end
