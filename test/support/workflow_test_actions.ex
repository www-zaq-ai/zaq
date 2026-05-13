defmodule Zaq.Engine.Workflows.Test.AlwaysCondition do
  @moduledoc false
  def call(_fact), do: true
end

defmodule Zaq.Engine.Workflows.Test.NeverCondition do
  @moduledoc false
  def call(_fact), do: false
end

defmodule Zaq.Engine.Workflows.Test.OkAction do
  @moduledoc false
  use Jido.Action, name: "test_ok_action", schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{value: "done"}}
end

defmodule Zaq.Engine.Workflows.Test.ErrorAction do
  @moduledoc false
  use Jido.Action, name: "test_error_action", schema: []

  @impl true
  def run(_params, _context), do: {:error, :test_failure}
end
