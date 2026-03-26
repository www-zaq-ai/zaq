defmodule ZaqWeb.E2EController do
  @moduledoc false

  use ZaqWeb, :controller

  alias Zaq.E2E.ProcessorState

  def fail(conn, params) do
    count = params |> Map.get("count", "1") |> String.to_integer()
    ProcessorState.set_fail(count)
    json(conn, %{ok: true, fail_count: count})
  end

  def reset(conn, _params) do
    ProcessorState.reset()
    json(conn, %{ok: true})
  end
end
