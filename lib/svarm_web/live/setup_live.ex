defmodule SvarmWeb.SetupLive do
  @moduledoc """
  In-app setup preflight: OpenRouter, tracker, default agent model, Apply to live swarm.
  """
  use SvarmWeb, :live_view

  alias Svarm.{Orchestrator, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_setup(socket)}
  end

  @impl true
  def handle_event("validate", %{"setup" => params}, socket) do
    form = normalize_params(params)
    readiness = readiness(form, socket.assigns)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:dirty?, form_dirty?(form, socket.assigns.baseline))
     |> assign(:readiness, readiness)
     |> assign(:next_step, next_step(readiness, form, socket.assigns.status))}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, assign_setup(socket)}
  end

  def handle_event("pick_model", %{"model" => model}, socket) do
    form = Map.put(socket.assigns.form, "agent_model", model)
    readiness = readiness(form, socket.assigns)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:dirty?, form_dirty?(form, socket.assigns.baseline))
     |> assign(:readiness, readiness)
     |> assign(:next_step, next_step(readiness, form, socket.assigns.status))}
  end

  def handle_event("test_provider", _params, socket) do
    socket = assign(socket, :testing, :provider)

    case Settings.test_provider() do
      {:ok, %{count: count, models: models}} ->
        {:noreply,
         socket
         |> assign(:testing, nil)
         |> assign(:provider_test, {:ok, count})
         |> assign(:model_suggestions, models)
         |> put_flash(:info, "OpenRouter OK — #{count} models available")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:testing, nil)
         |> assign(:provider_test, {:error, reason})
         |> put_flash(:error, "OpenRouter test failed: #{reason}")}
    end
  end

  def handle_event("test_tracker", _params, socket) do
    socket = assign(socket, :testing, :tracker)

    case Settings.test_tracker(socket.assigns.form) do
      {:ok, :local} ->
        {:noreply,
         socket
         |> assign(:testing, nil)
         |> assign(:tracker_test, {:ok, :local})
         |> put_flash(:info, "Local board tracker ready")}

      {:ok, count} when is_integer(count) ->
        {:noreply,
         socket
         |> assign(:testing, nil)
         |> assign(:tracker_test, {:ok, count})
         |> put_flash(:info, "GitHub OK — #{count} open eligible issues")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:testing, nil)
         |> assign(:tracker_test, {:error, reason})
         |> put_flash(:error, "Tracker test failed: #{reason}")}
    end
  end

  def handle_event("save_and_apply", %{"setup" => params}, socket) do
    form = normalize_params(params)
    socket = assign(socket, form: form, applying?: true)

    with :ok <- save_all(form),
         {:ok, summary} <- Orchestrator.reload_config() do
      msg =
        "Applied to live swarm — #{summary.agent_count} agents, tracker #{summary.tracker_kind}"

      {:noreply,
       socket
       |> put_flash(:info, msg)
       |> assign(:applying?, false)
       |> assign(:last_apply, summary)
       |> assign_setup()}
    else
      {:error, :save, section, reason} ->
        {:noreply,
         socket
         |> assign(:applying?, false)
         |> put_flash(:error, save_error_message(section, reason))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:applying?, false)
         |> put_flash(:error, apply_error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:setup}>
      <div class="max-w-2xl mx-auto pb-36 sm:pb-28">
        <header class="mb-5">
          <p class="text-xs font-medium text-base-content/55">Preflight</p>
          <h1 class="mt-0.5 text-2xl font-semibold tracking-tight">Setup</h1>
          <p class="mt-2 text-sm text-base-content/70 max-w-prose">
            Connect OpenRouter and your tracker, then apply to the live orchestrator.
            Secrets stay encrypted; file/env config still works when empty.
          </p>
        </header>

        <.preflight_strip
          readiness={@readiness}
          status={@status}
          next_step={@next_step}
          last_apply={@last_apply}
        />

        <form id="setup-form" phx-change="validate" phx-submit="save_and_apply" class="mt-5 space-y-4">
          <.connection_section
            id="provider"
            title="1 · Provider"
            badge={@readiness.provider.badge}
            ready?={@readiness.provider.ready?}
            hint="OpenRouter API key for agent LLM calls."
          >
            <:actions>
              <button
                type="button"
                phx-click="test_provider"
                class="btn btn-xs btn-outline min-h-8"
                disabled={@testing == :provider}
                aria-busy={@testing == :provider}
                phx-disable-with="Testing…"
              >
                Test connection
              </button>
            </:actions>

            <label class="form-control w-full gap-1" for="setup-provider-api-key">
              <span class="label-text text-xs text-base-content/55">API key</span>
              <input
                id="setup-provider-api-key"
                type="password"
                name="setup[provider_api_key]"
                class="input input-bordered input-sm w-full font-mono"
                value={@form["provider_api_key"]}
                placeholder={provider_placeholder(@provider, @status)}
                autocomplete="off"
              />
            </label>

            <p
              :if={provider_test_ok(@provider_test)}
              class="text-xs font-mono text-base-content/70"
              role="status"
            >
              Last test: OK ({provider_test_ok(@provider_test)} models)
            </p>
            <p :if={test_error(@provider_test)} class="text-xs text-error" role="alert">
              Last test failed: {test_error(@provider_test)}
            </p>
          </.connection_section>

          <.connection_section
            id="tracker"
            title="2 · Tracker"
            badge={@readiness.tracker.badge}
            ready?={@readiness.tracker.ready?}
            hint={tracker_hint(@form["tracker_kind"], @status.tracker_source)}
          >
            <:actions>
              <button
                type="button"
                phx-click="test_tracker"
                class="btn btn-xs btn-outline min-h-8"
                disabled={@testing == :tracker}
                aria-busy={@testing == :tracker}
                phx-disable-with="Testing…"
              >
                Test connection
              </button>
            </:actions>

            <label class="form-control w-full gap-1" for="setup-tracker-kind">
              <span class="label-text text-xs text-base-content/55">Source</span>
              <select
                id="setup-tracker-kind"
                name="setup[tracker_kind]"
                class="select select-bordered select-sm w-full"
              >
                <option value="local" selected={@form["tracker_kind"] == "local"}>
                  Local board (no GitHub)
                </option>
                <option value="github" selected={@form["tracker_kind"] == "github"}>
                  GitHub issues
                </option>
              </select>
            </label>

            <div :if={@form["tracker_kind"] == "github"} class="space-y-3">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label class="form-control w-full gap-1" for="setup-tracker-owner">
                  <span class="label-text text-xs text-base-content/55">Owner</span>
                  <input
                    id="setup-tracker-owner"
                    type="text"
                    name="setup[tracker_owner]"
                    value={@form["tracker_owner"]}
                    class="input input-bordered input-sm w-full font-mono"
                    autocomplete="off"
                  />
                </label>
                <label class="form-control w-full gap-1" for="setup-tracker-repo">
                  <span class="label-text text-xs text-base-content/55">Repo</span>
                  <input
                    id="setup-tracker-repo"
                    type="text"
                    name="setup[tracker_repo]"
                    value={@form["tracker_repo"]}
                    class="input input-bordered input-sm w-full font-mono"
                    autocomplete="off"
                  />
                </label>
              </div>
              <label class="form-control w-full gap-1" for="setup-tracker-api-key">
                <span class="label-text text-xs text-base-content/55">GitHub PAT</span>
                <input
                  id="setup-tracker-api-key"
                  type="password"
                  name="setup[tracker_api_key]"
                  class="input input-bordered input-sm w-full font-mono"
                  value={@form["tracker_api_key"]}
                  placeholder={tracker_placeholder(@tracker)}
                  autocomplete="off"
                />
              </label>
              <label class="form-control w-full gap-1" for="setup-tracker-labels">
                <span class="label-text text-xs text-base-content/55">
                  Required labels (comma-separated)
                </span>
                <input
                  id="setup-tracker-labels"
                  type="text"
                  name="setup[tracker_labels]"
                  value={@form["tracker_labels"]}
                  class="input input-bordered input-sm w-full font-mono"
                  placeholder="ai-task"
                  autocomplete="off"
                />
              </label>
            </div>

            <p :if={@form["tracker_kind"] == "local"} class="text-xs text-base-content/55">
              Uses the in-app kanban. No owner, repo, or PAT required.
            </p>

            <p
              :if={tracker_test_ok_local?(@tracker_test)}
              class="text-xs font-mono text-base-content/70"
              role="status"
            >
              Last test: local board ready
            </p>
            <p
              :if={tracker_test_ok_count(@tracker_test)}
              class="text-xs font-mono text-base-content/70"
              role="status"
            >
              Last test: OK ({tracker_test_ok_count(@tracker_test)} eligible issues)
            </p>
            <p :if={test_error(@tracker_test)} class="text-xs text-error" role="alert">
              Last test failed: {test_error(@tracker_test)}
            </p>
          </.connection_section>

          <.connection_section
            id="agent"
            title="3 · Default agent"
            badge={@readiness.agent.badge}
            ready?={@readiness.agent.ready?}
            hint="Model for the default agent only (overrides file config for default)."
          >
            <input type="hidden" name="setup[agent_provider]" value="openrouter" />

            <p :if={@effective_model} class="text-xs font-mono text-base-content/55">
              Live default: <span class="text-base-content">{@effective_model}</span>
            </p>

            <label class="form-control w-full gap-1" for="setup-agent-model">
              <span class="label-text text-xs text-base-content/55">Default model</span>
              <input
                id="setup-agent-model"
                type="text"
                name="setup[agent_model]"
                value={@form["agent_model"]}
                class="input input-bordered input-sm w-full font-mono"
                placeholder="openrouter/free"
                autocomplete="off"
              />
            </label>

            <div :if={@model_suggestions != []} class="space-y-1.5">
              <p class="text-xs text-base-content/55">From last provider test</p>
              <div class="flex flex-wrap gap-1.5" role="list">
                <button
                  :for={model <- Enum.take(@model_suggestions, 8)}
                  type="button"
                  role="listitem"
                  phx-click="pick_model"
                  phx-value-model={model}
                  class={[
                    "btn btn-xs font-mono max-w-full truncate border",
                    if(@form["agent_model"] == model,
                      do: "btn-primary",
                      else: "btn-ghost border-base-300"
                    )
                  ]}
                  title={model}
                >
                  {model}
                </button>
              </div>
            </div>

            <p class="text-xs text-base-content/55">
              Test connection to load model chips, or paste an OpenRouter model id.
            </p>
          </.connection_section>

          <div class="fixed bottom-0 inset-x-0 z-30 border-t border-base-300 bg-base-100/95 backdrop-blur-sm pb-[env(safe-area-inset-bottom)]">
            <div class="max-w-2xl mx-auto px-4 py-3 sm:px-6 lg:px-8 flex flex-col-reverse sm:flex-row sm:items-center gap-3 sm:justify-between">
              <div class="min-w-0 sm:pr-4">
                <p class="text-sm font-medium leading-snug">
                  <%= cond do %>
                    <% @dirty? -> %>
                      Unapplied changes
                    <% @readiness.complete? -> %>
                      Ready for the board
                    <% true -> %>
                      Apply when the checklist is ready
                  <% end %>
                </p>
                <p class="text-xs text-base-content/55 mt-0.5">
                  Reloads agents and tracker without restarting the node.
                </p>
              </div>
              <div class="flex items-center gap-2 shrink-0 w-full sm:w-auto">
                <button
                  :if={@dirty?}
                  type="button"
                  phx-click="discard"
                  class="btn btn-ghost btn-sm flex-1 sm:flex-none"
                >
                  Discard
                </button>
                <a
                  :if={@readiness.complete? and not @dirty?}
                  href={~p"/board"}
                  class="btn btn-ghost btn-sm flex-1 sm:flex-none"
                >
                  Open board
                </a>
                <button
                  type="submit"
                  class={[
                    "btn btn-primary flex-1 sm:flex-none",
                    @dirty? && "ring-2 ring-primary/30"
                  ]}
                  disabled={@applying?}
                  phx-disable-with="Applying…"
                >
                  {if @applying?, do: "Applying…", else: "Apply to live swarm"}
                </button>
              </div>
            </div>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  ## components

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, required: true
  attr :ready?, :boolean, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true
  slot :actions

  defp connection_section(assigns) do
    ~H"""
    <section
      id={"section-#{@id}"}
      class="rounded-lg border border-base-300 bg-base-200/40 p-4 sm:p-5 space-y-3.5 scroll-mt-24"
      aria-labelledby={"heading-#{@id}"}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <h2 id={"heading-#{@id}"} class="font-semibold text-base tracking-tight">
              {@title}
            </h2>
            <span class={[
              "badge badge-sm font-mono",
              badge_class(@badge, @ready?)
            ]}>
              <span class="sr-only">{badge_sr(@badge)}</span>
              {badge_label(@badge)}
            </span>
          </div>
          <p class="mt-1 text-xs text-base-content/55">{@hint}</p>
        </div>
        <div class="shrink-0">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :readiness, :map, required: true
  attr :status, :map, required: true
  attr :next_step, :string, required: true
  attr :last_apply, :any, default: nil

  defp preflight_strip(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-base-300 bg-base-200/50 p-3.5 space-y-2.5"
      aria-label="Setup readiness"
    >
      <div class="flex flex-wrap gap-1.5">
        <.chip
          ok?={@readiness.provider.ready?}
          label="Provider"
          href="#section-provider"
          pending?={@readiness.provider.badge == "pending"}
        />
        <.chip
          ok?={@readiness.tracker.ready?}
          label={"Tracker · #{tracker_source_label(@status.tracker_source)}"}
          href="#section-tracker"
          pending?={@readiness.tracker.badge == "pending"}
        />
        <.chip
          ok?={@readiness.agent.ready?}
          label={agent_chip_label(@readiness, @status)}
          href="#section-agent"
          pending?={@readiness.agent.badge == "pending"}
        />
        <.chip ok?={@readiness.complete?} label="Swarm ready" />
      </div>
      <p class="text-sm leading-snug">
        <span class="text-base-content/55">Next</span>
        <span class="mx-1.5 text-base-content/30" aria-hidden="true">·</span>
        <span class="font-medium">{@next_step}</span>
      </p>
      <p :if={@last_apply} class="text-xs font-mono text-base-content/55" role="status">
        Last apply: {@last_apply.agent_count} agents · tracker {@last_apply.tracker_kind}
      </p>
    </div>
    """
  end

  attr :ok?, :boolean, required: true
  attr :label, :string, required: true
  attr :href, :string, default: nil
  attr :pending?, :boolean, default: false

  defp chip(%{href: href} = assigns) when is_binary(href) and href != "" do
    ~H"""
    <a
      href={@href}
      class={[
        "badge badge-sm font-mono no-underline hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
        chip_class(@ok?, @pending?)
      ]}
    >
      <span class="sr-only">{chip_sr(@ok?, @pending?)}</span>
      {chip_glyph(@ok?, @pending?)} {@label}
    </a>
    """
  end

  defp chip(assigns) do
    ~H"""
    <span class={["badge badge-sm font-mono", chip_class(@ok?, @pending?)]}>
      <span class="sr-only">{chip_sr(@ok?, @pending?)}</span>
      {chip_glyph(@ok?, @pending?)} {@label}
    </span>
    """
  end

  ## data

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
    form = build_form(provider, tracker, agent)
    baseline = form_snapshot(form, provider, tracker)
    assigns_base = %{provider: provider, tracker: tracker, agent: agent, status: status}
    readiness = readiness(form, assigns_base)

    socket
    |> assign(:status, status)
    |> assign(:provider, provider)
    |> assign(:tracker, tracker)
    |> assign(:agent, agent)
    |> assign(:form, form)
    |> assign(:baseline, baseline)
    |> assign(:dirty?, false)
    |> assign(:applying?, false)
    |> assign(:testing, nil)
    |> assign(:readiness, readiness)
    |> assign(:next_step, next_step(readiness, form, status))
    |> assign(:effective_model, status[:default_model])
    |> assign_new(:provider_test, fn -> nil end)
    |> assign_new(:tracker_test, fn -> nil end)
    |> assign_new(:last_apply, fn -> nil end)
    |> assign_new(:model_suggestions, fn -> [] end)
  end

  defp build_form(provider, tracker, agent) do
    provider = stringify_map(provider)
    tracker = stringify_map(tracker)
    agent = stringify_map(agent)

    %{
      "provider_api_key" => "",
      "tracker_kind" => to_string(tracker["kind"] || "local"),
      "tracker_owner" => tracker["owner"] || "",
      "tracker_repo" => tracker["repo"] || "",
      "tracker_api_key" => "",
      "tracker_labels" => labels_to_csv(tracker["required_labels"]),
      "agent_provider" => agent["provider"] || "openrouter",
      "agent_model" => agent["model"] || provider["default_model"] || ""
    }
  end

  # Prefer atom-derived keys when both atom and string forms exist for the same name.
  defp stringify_map(map) when is_map(map) do
    strings =
      Enum.reduce(map, %{}, fn
        {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
        {k, v}, acc when not is_atom(k) -> Map.put(acc, to_string(k), v)
        {_k, _v}, acc -> acc
      end)

    Enum.reduce(map, strings, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {_k, _v}, acc -> acc
    end)
  end

  defp labels_to_csv(list) when is_list(list), do: Enum.join(list, ", ")
  defp labels_to_csv(bin) when is_binary(bin), do: bin
  defp labels_to_csv(_), do: ""

  defp normalize_params(params) when is_map(params) do
    %{
      "provider_api_key" => blank_to_empty(params["provider_api_key"]),
      "tracker_kind" =>
        if(params["tracker_kind"] in ["local", "github"],
          do: params["tracker_kind"],
          else: "local"
        ),
      "tracker_owner" => blank_to_empty(params["tracker_owner"]),
      "tracker_repo" => blank_to_empty(params["tracker_repo"]),
      "tracker_api_key" => blank_to_empty(params["tracker_api_key"]),
      "tracker_labels" => blank_to_empty(params["tracker_labels"]),
      "agent_provider" => agent_provider_param(params["agent_provider"]),
      "agent_model" => blank_to_empty(params["agent_model"])
    }
  end

  defp blank_to_empty(v) when is_binary(v), do: v
  defp blank_to_empty(_), do: ""

  defp agent_provider_param(v) do
    case blank_to_empty(v) do
      "" -> "openrouter"
      other -> other
    end
  end

  defp form_snapshot(form, provider, tracker) do
    %{
      "tracker_kind" => form["tracker_kind"],
      "tracker_owner" => form["tracker_owner"],
      "tracker_repo" => form["tracker_repo"],
      "tracker_labels" => form["tracker_labels"],
      "agent_model" => form["agent_model"],
      "provider_key_set?" => !!provider[:api_key_set?],
      "tracker_key_set?" => !!tracker[:api_key_set?]
    }
  end

  defp form_dirty?(form, baseline) do
    form["provider_api_key"] != "" or
      form["tracker_api_key"] != "" or
      form["tracker_kind"] != baseline["tracker_kind"] or
      form["tracker_owner"] != baseline["tracker_owner"] or
      form["tracker_repo"] != baseline["tracker_repo"] or
      form["tracker_labels"] != baseline["tracker_labels"] or
      form["agent_model"] != baseline["agent_model"]
  end

  # Projected readiness after Apply (form + stored secrets + live env).
  defp readiness(form, assigns) do
    provider = provider_readiness(form, assigns)
    tracker = tracker_readiness(form, assigns)
    agent = agent_readiness(form, assigns)

    %{
      provider: provider,
      tracker: tracker,
      agent: agent,
      complete?: provider.ready? and tracker.ready? and agent.ready?
    }
  end

  defp provider_readiness(form, assigns) do
    ready? =
      present?(form["provider_api_key"]) or assigns.provider[:api_key_set?] == true or
        assigns.status.provider_configured? == true

    pending? =
      ready? and assigns.status.provider_configured? != true and
        (present?(form["provider_api_key"]) or assigns.provider[:api_key_set?] == true)

    %{ready?: ready?, badge: readiness_badge(ready?, pending?)}
  end

  defp tracker_readiness(form, assigns) do
    ready? = tracker_form_ready?(form, assigns.tracker)
    # Pending when the form is ready but live status has not caught up yet.
    pending? = ready? and not assigns.status.tracker_ready?
    %{ready?: ready?, badge: readiness_badge(ready?, pending?)}
  end

  defp tracker_form_ready?(form, tracker) do
    case form["tracker_kind"] do
      "local" ->
        true

      "github" ->
        present?(form["tracker_owner"]) and present?(form["tracker_repo"]) and
          (present?(form["tracker_api_key"]) or tracker[:api_key_set?] == true)

      _ ->
        false
    end
  end

  defp agent_readiness(form, assigns) do
    ready? =
      present?(form["agent_model"]) or present?(assigns.agent["model"]) or
        assigns.status[:default_model_set?] == true

    pending? =
      ready? and assigns.status[:default_model_set?] != true and present?(form["agent_model"])

    %{ready?: ready?, badge: readiness_badge(ready?, pending?)}
  end

  defp readiness_badge(_ready?, true), do: "pending"
  defp readiness_badge(true, false), do: "ready"
  defp readiness_badge(false, false), do: "needed"

  defp next_step(%{provider: %{ready?: false}}, _form, _status) do
    "Add an OpenRouter API key, then apply."
  end

  defp next_step(%{tracker: %{badge: "needed"}}, %{"tracker_kind" => "github"}, _status) do
    "Add GitHub owner, repo, and PAT, then apply."
  end

  defp next_step(%{tracker: %{badge: "pending"}}, %{"tracker_kind" => "local"}, _status) do
    "Apply to use Local board tracker."
  end

  defp next_step(%{agent: %{ready?: false}}, _form, _status) do
    "Set a default model, then apply."
  end

  defp next_step(%{complete?: true, tracker: %{badge: "pending"}}, _form, _status) do
    "Apply to load these settings into the running orchestrator."
  end

  defp next_step(%{complete?: true}, _form, %{setup_complete?: false}) do
    "Apply to load these settings into the running orchestrator."
  end

  defp next_step(%{complete?: true}, _form, _status) do
    "Apply if you changed anything, or open the board."
  end

  defp next_step(_readiness, _form, _status) do
    "Complete the steps above, then apply."
  end

  defp save_all(form) do
    provider_attrs = %{
      "api_key" => form["provider_api_key"],
      "default_model" => form["agent_model"]
    }

    tracker_attrs = %{
      "kind" => form["tracker_kind"],
      "owner" => form["tracker_owner"],
      "repo" => form["tracker_repo"],
      "api_key" => form["tracker_api_key"],
      "auth" => "token",
      "required_labels" => parse_labels(form["tracker_labels"])
    }

    agent_attrs = %{
      "provider" => form["agent_provider"] || "openrouter",
      "model" => form["agent_model"]
    }

    with {:ok, _} <- save_section(:provider, fn -> Settings.put_provider(provider_attrs) end),
         {:ok, _} <- save_section(:tracker, fn -> Settings.put_tracker(tracker_attrs) end),
         {:ok, _} <- save_section(:agent, fn -> Settings.put_default_agent(agent_attrs) end) do
      :ok
    end
  end

  defp save_section(section, fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, :save, section, reason}
    end
  end

  defp parse_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_labels(_), do: []

  defp provider_placeholder(provider, status) do
    cond do
      provider[:api_key_set?] -> "•••• set — leave blank to keep"
      status.provider_configured? -> "Configured via file/env — paste to replace"
      true -> "sk-or-…"
    end
  end

  defp tracker_placeholder(tracker) do
    if tracker[:api_key_set?], do: "•••• set — leave blank to keep", else: "ghp_…"
  end

  defp tracker_hint("github", source),
    do: "GitHub issues · config from #{tracker_source_label(source)}. Needs owner, repo, and PAT."

  defp tracker_hint(_, source),
    do: "Local in-app board · config from #{tracker_source_label(source)}."

  defp tracker_source_label("settings"), do: "in-app settings"
  defp tracker_source_label("file"), do: "file / env"
  defp tracker_source_label(other) when is_binary(other), do: other
  defp tracker_source_label(_), do: "file / env"

  defp agent_chip_label(readiness, status) do
    model = status[:default_model]

    cond do
      readiness.agent.ready? and present?(model) -> "Model · #{short_model(model)}"
      readiness.agent.ready? -> "Default model"
      true -> "Default model"
    end
  end

  defp short_model(model) when is_binary(model) and byte_size(model) > 28 do
    String.slice(model, 0, 25) <> "…"
  end

  defp short_model(model), do: model

  defp badge_class("ready", _), do: "badge-ghost border border-base-300 text-base-content/80"
  defp badge_class("pending", _), do: "badge-ghost border border-warning/40 text-warning"
  defp badge_class(_, _), do: "badge-ghost text-base-content/70"

  defp badge_label("ready"), do: "Ready"
  defp badge_label("pending"), do: "Pending apply"
  defp badge_label(_), do: "Needed"

  defp badge_sr("ready"), do: "Ready: "
  defp badge_sr("pending"), do: "Pending apply: "
  defp badge_sr(_), do: "Not ready: "

  defp chip_class(true, true), do: "badge-ghost border border-warning/40 text-warning"
  defp chip_class(true, _), do: "badge-ghost border border-base-300 text-base-content/80"
  defp chip_class(_, _), do: "badge-ghost text-base-content/70"

  defp chip_glyph(true, true), do: "◌"
  defp chip_glyph(true, _), do: "✓"
  defp chip_glyph(_, _), do: "○"

  defp chip_sr(true, true), do: "Pending apply: "
  defp chip_sr(true, _), do: "Ready: "
  defp chip_sr(_, _), do: "Not ready: "

  defp save_error_message(:provider, _),
    do: "Could not save provider settings. Check the API key and try again."

  defp save_error_message(:tracker, _),
    do: "Could not save tracker settings. Check owner, repo, and PAT."

  defp save_error_message(:agent, _), do: "Could not save default agent model."
  defp save_error_message(_, _), do: "Could not save settings."

  defp apply_error_message(reason) when is_atom(reason),
    do: "Apply failed: #{reason}. Fix configuration and try again."

  defp apply_error_message(reason) when is_binary(reason), do: "Apply failed: #{reason}"

  defp apply_error_message(%{message: msg}) when is_binary(msg), do: "Apply failed: #{msg}"

  defp apply_error_message(_),
    do: "Apply failed. Check provider, tracker, and agents.toml, then try again."

  defp provider_test_ok({:ok, count}) when is_integer(count), do: count
  defp provider_test_ok(_), do: nil

  defp tracker_test_ok_local?({:ok, :local}), do: true
  defp tracker_test_ok_local?(_), do: false

  defp tracker_test_ok_count({:ok, count}) when is_integer(count), do: count
  defp tracker_test_ok_count(_), do: nil

  defp test_error({:error, reason}), do: reason
  defp test_error(_), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
