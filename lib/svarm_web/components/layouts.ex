defmodule SvarmWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SvarmWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active_nav, :atom,
    default: nil,
    doc: "which primary nav item is current (:dashboard | :board | :setup | :approvals)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar min-h-14 gap-3 px-4 sm:px-6 lg:px-8">
      <div class="navbar-start shrink-0">
        <a href="/" class="flex items-center gap-2 no-underline text-base-content">
          <img src={~p"/images/logo.svg"} width="32" height="32" alt="" class="size-8" />
          <span class="text-sm font-semibold tracking-tight">Svärm</span>
        </a>
      </div>
      <div class="navbar-end min-w-0">
        <nav aria-label="Primary" class="flex items-center gap-0.5 sm:gap-1 overflow-x-auto">
          <a
            href={~p"/dashboard"}
            class={["btn btn-ghost btn-sm", @active_nav == :dashboard && "btn-active"]}
            aria-current={@active_nav == :dashboard && "page"}
          >
            Dashboard
          </a>
          <a
            href={~p"/board"}
            class={["btn btn-ghost btn-sm", @active_nav == :board && "btn-active"]}
            aria-current={@active_nav == :board && "page"}
          >
            Board
          </a>
          <a
            href={~p"/setup"}
            class={["btn btn-ghost btn-sm", @active_nav == :setup && "btn-active"]}
            aria-current={@active_nav == :setup && "page"}
          >
            Setup
          </a>
          <a
            href={~p"/approvals"}
            class={["btn btn-ghost btn-sm", @active_nav == :approvals && "btn-active"]}
            aria-current={@active_nav == :approvals && "page"}
          >
            Approvals
          </a>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  System / light / dark control. Themes live in `assets/css/app.css`.
  Root script in `root.html.heex` applies `data-theme` before paint.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-toggle-text" role="group" aria-label="Color theme">
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System"
        aria-label="System theme"
      >
        Auto
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light"
        aria-label="Light theme"
      >
        Light
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark"
        aria-label="Dark theme"
      >
        Dark
      </button>
    </div>
    """
  end
end
