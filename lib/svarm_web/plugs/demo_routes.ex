defmodule SvarmWeb.Plugs.DemoRoutes do
  @moduledoc """
  Gates `/dev/demo/*` — available in local dev (`dev_routes`) or when
  `SVARM_DEMO_ROUTES=1` / `SVARM_SEED_DEMO=1` is set at runtime.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Svarm.Demo.routes_enabled?() do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Demo routes disabled. Set SVARM_DEMO_ROUTES=1 to enable Seed demo.")
      |> halt()
    end
  end
end
