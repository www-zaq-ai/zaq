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

# ---------------------------------------------------------------------------
# Pause / Resume test support
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.PauseSignal do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def put_run_id(run_id), do: Agent.update(__MODULE__, fn _ -> run_id end)
  def get_run_id, do: Agent.get(__MODULE__, & &1)
  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.PauseAction do
  @moduledoc false
  use Jido.Action,
    name: "test_pause_action",
    schema: [input: [type: :any]],
    output_schema: [signaled: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.PauseSignal

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context) do
    run_id = PauseSignal.get_run_id()
    run = Workflows.get_run!(run_id)
    {:ok, _} = Workflows.update_run(run, %{status: "paused"})
    {:ok, %{signaled: true}}
  end
end

# ---------------------------------------------------------------------------
# Actions for Step 6 edge-routing E2E test
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.Noop do
  @moduledoc false
  use Jido.Action,
    name: "test_noop",
    schema: [input: [type: :any]],
    output_schema: [noop: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{noop: true}}
end

defmodule Zaq.Engine.Workflows.Test.EmitPerson do
  @moduledoc false

  use Jido.Action,
    name: "test_emit_person",
    schema: [gender: [type: :string, required: true]],
    output_schema: [
      name: [type: :string, required: true],
      age: [type: :integer, required: true],
      gender: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    gender = Map.get(params, :gender) || Map.get(params, "gender")
    {:ok, %{name: "Sam", age: 30, gender: gender}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RequirePersonName do
  @moduledoc false

  use Jido.Action,
    name: "test_require_person_name",
    schema: [person_name: [type: :any]],
    output_schema: [
      c_ran: [type: :boolean, required: true],
      person_name: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    # Asserts mapping correctness: person_name present, raw name must NOT be present.
    person_name = Map.fetch!(params, :person_name)

    if Map.has_key?(params, :name),
      do: raise("C received raw :name key — mapping isolation failed")

    {:ok, %{c_ran: true, person_name: person_name}}
  end
end

defmodule Zaq.Engine.Workflows.Test.EmitGender do
  @moduledoc false
  use Jido.Action,
    name: "test_emit_gender",
    schema: [gender: [type: :string, required: true]],
    output_schema: [gender: [type: :string, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    gender = Map.get(params, :gender) || Map.get(params, "gender")
    {:ok, %{gender: gender}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RequireFirstName do
  @moduledoc false

  use Jido.Action,
    name: "test_require_first_name",
    schema: [first_name: [type: :any]],
    output_schema: [
      f_ran: [type: :boolean, required: true],
      first_name: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    first_name = Map.fetch!(params, :first_name)

    if Map.has_key?(params, :name),
      do: raise("F received raw :name key — mapping isolation failed")

    {:ok, %{f_ran: true, first_name: first_name}}
  end
end
