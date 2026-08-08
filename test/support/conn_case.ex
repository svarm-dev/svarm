defmodule SvarmWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Database-backed tests share a per-run SQLite file under the system
  temp directory (see `config/test.exs`). There is no Ecto SQL sandbox
  and no per-test transaction rollback. Prefer `async: false` whenever
  a test touches Repo, KanbanBridge, or the shared Orchestrator GenServer;
  `async: true` is only safe for pure connection tests that never share
  that state.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SvarmWeb.Endpoint

      use SvarmWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SvarmWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
