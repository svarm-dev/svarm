defmodule SvarmWeb.Router do
  use SvarmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SvarmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :approvals do
    plug :browser
    plug SvarmWeb.Plugs.ApprovalsAuth
  end

  scope "/", SvarmWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/board", BoardLive, :index
  end

  scope "/", SvarmWeb do
    pipe_through :approvals

    get "/approvals", ApprovalsController, :index
    post "/approvals/:id/approve", ApprovalsController, :approve
    post "/approvals/:id/reject", ApprovalsController, :reject
  end

  # Other scopes may use custom stacks.
  # scope "/api", SvarmWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:svarm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev", SvarmWeb do
      pipe_through :browser

      post "/demo/seed", DevDemoController, :seed
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SvarmWeb.Telemetry
    end
  end
end
