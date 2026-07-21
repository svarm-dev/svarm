defmodule SvarmWeb.LiveCase do
  @moduledoc """
  Test case for LiveViews.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SvarmWeb.Endpoint

      use SvarmWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import SvarmWeb.LiveCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
