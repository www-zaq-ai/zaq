defmodule Zaq.Engine.Workflows.CancelledErrorTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.CancelledError

  test "exception/1 includes run_id in struct and message" do
    error = CancelledError.exception(run_id: 123)

    assert %CancelledError{run_id: 123, message: "workflow run 123 cancelled"} = error
  end
end
