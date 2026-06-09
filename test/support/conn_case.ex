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

    # Default portal client behaviour for every ConnCase test: behave as if the
    # portal is unreachable. The shared `bo_layout` mounts `PortalConsentLive`,
    # so every BO LiveView test calls `fetch_onboarding/1` on mount — without
    # this stub those calls would raise `Mox.UnexpectedCallError`. Tests that
    # exercise portal flows override these with their own `Mox.expect`/`stub`
    # (directly or via `Zaq.PortalStubs`). The stub is per-process (inherited by
    # spawned LiveViews through Mox's `$callers`), so async tests stay race-free.
    Mox.stub_with(Zaq.UserPortal.ClientMock, Zaq.UserPortal.ClientStub)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
