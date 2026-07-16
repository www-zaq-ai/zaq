defmodule Zaq.TimezoneTestHelpers do
  @moduledoc """
  Stubs the `:system_timezone_fun` app env for tests.

  The app env is global, so a bare `Application.put_env/3` leaks into every
  other test in the run. This helper captures the previous value and restores
  it on exit — including deleting the key when it was never set, so tests that
  rely on the unset default stay honest.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets `:system_timezone_fun` to return `tz` (default `nil`, i.e. no
  configured timezone) and restores the previous env value on test exit.
  """
  def stub_system_timezone(tz \\ nil) do
    previous = Application.fetch_env(:zaq, :system_timezone_fun)
    Application.put_env(:zaq, :system_timezone_fun, fn -> tz end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaq, :system_timezone_fun, value)
        :error -> Application.delete_env(:zaq, :system_timezone_fun)
      end
    end)

    :ok
  end
end
