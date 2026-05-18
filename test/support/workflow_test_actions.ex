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

defmodule Zaq.Engine.Workflows.Test.ParamCapture do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  def put_params(params), do: Agent.update(__MODULE__, fn _ -> params end)

  def get_params, do: Agent.get(__MODULE__, & &1)

  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.ParamProbe do
  @moduledoc false
  use Jido.Action, name: "test_param_probe", schema: []

  alias Zaq.Engine.Workflows.Test.ParamCapture

  @impl true
  def run(params, _context) do
    ParamCapture.put_params(params)
    {:ok, %{params_captured: true}}
  end
end
