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
  use Jido.Action,
    name: "test_ok_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{value: "done"}}
end

defmodule Zaq.Engine.Workflows.Test.ErrorAction do
  @moduledoc false
  use Jido.Action,
    name: "test_error_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:error, :test_failure}
end

defmodule Zaq.Engine.Workflows.Test.NonConformingAction do
  @moduledoc false
  # A loadable Jido.Action that does NOT satisfy the workflow action contract:
  # empty schema, no output_schema, no on_success/2 or on_failure/2.
  use Jido.Action, name: "test_non_conforming_action", schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{value: "done"}}
end

defmodule Zaq.Engine.Workflows.Test.ParamCapture do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  def put_params(params), do: Agent.update(__MODULE__, fn _ -> params end)

  def get_params, do: Agent.get(__MODULE__, & &1)

  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.OkWithLogsAction do
  @moduledoc false
  use Jido.Action,
    name: "test_ok_with_logs_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context),
    do: {:ok, %{value: "with_logs"}, logs: [%{level: "info", message: "step log"}]}
end

defmodule Zaq.Engine.Workflows.Test.ParamProbe do
  @moduledoc false
  use Jido.Action,
    name: "test_param_probe",
    schema: [input: [type: :any]],
    output_schema: [params_captured: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.Test.ParamCapture

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    ParamCapture.put_params(params)
    {:ok, %{params_captured: true}}
  end
end
