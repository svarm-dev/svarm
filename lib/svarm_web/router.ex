defmodule SvarmWeb.Router do
  use SvarmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SvarmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Capture Basic Auth proof for board mutations (does not block reads)
    plug SvarmWeb.Plugs.BoardAuthCapture
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :approvals do
    plug :browser
    plug SvarmWeb.Plugs.ApprovalsAuth
  end

  # Plain-text health — no browser pipeline (no CSRF/session); Docker HEALTHCHECK target.
  get "/health", SvarmWeb.PageController, :health

  scope "/", SvarmWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Board/dashboard reads: optional Basic Auth (`BOARD_READ_AUTH`). The
  # `/live` websocket skips this plug — `BoardReadHook` covers mount.
  scope "/", SvarmWeb do
    pipe_through [:browser, SvarmWeb.Plugs.BoardReadAuth]

    live_session :board_reads, on_mount: [{SvarmWeb.Live.BoardReadHook, :default}] do
      live "/board", BoardLive, :index
      live "/dashboard", DashboardLive, :index
    end
  end

  scope "/", SvarmWeb do
    pipe_through :approvals

    get "/approvals", ApprovalsController, :index
    post "/approvals/:id/approve", ApprovalsController, :approve
    post "/approvals/:id/reject", ApprovalsController, :reject

    live "/setup", SetupLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", SvarmWeb do
  #   pipe_through :api
  # end

  # Seed demo — always compiled; gated at runtime by SvarmWeb.Plugs.DemoRoutes
  # (dev_routes or SVARM_DEMO_ROUTES / SVARM_SEED_DEMO).
  scope "/dev", SvarmWeb do
    pipe_through [:browser, SvarmWeb.Plugs.DemoRoutes]

    post "/demo/seed", DevDemoController, :seed
  end

  # LiveDashboard only in Mix dev (compile-time)
  if Application.compile_env(:svarm, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SvarmWeb.Telemetry
    end
  end
end
