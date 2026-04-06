defmodule ZaqWeb.ConnCase do
  @moduledoc """
  Base case for controller/plug tests that need a `Phoenix.ConnTest` connection.

  Imports `ConnTest` helpers and wraps each test in an Ecto SQL sandbox.
  Use `async: true` with PostgreSQL for parallel test runs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ZaqWeb.Endpoint

      use ZaqWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ZaqWeb.ConnCase
    end
  end

  setup tags do
    Zaq.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
