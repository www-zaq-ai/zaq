defmodule Zaq.ShutdownProbeApp do
  @moduledoc false
  # Minimal OTP application used inside a disposable peer VM to drive the real
  # `application_master` shutdown path in which the root supervisor has already
  # exited when `prep_stop/1` runs (children, including the run registry, gone).
  #
  # `mode: :zaq` delegates to the real `Zaq.Application.prep_stop/1`;
  # `mode: :failing` raises, as a control proving the log capture sees the
  # `shutdown_error` report OTP emits when a `prep_stop/1` callback fails.

  use Application

  @sup Zaq.ShutdownProbeApp.Supervisor
  @log Zaq.ShutdownProbeApp.Log

  def sup, do: @sup

  @impl true
  def start(_type, mode) do
    children = [{Registry, keys: :unique, name: Zaq.Engine.Workflows.RunRegistry}]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: @sup) do
      {:ok, pid, mode}
    end
  end

  @impl true
  def prep_stop(:failing), do: raise("prep_stop failed on purpose")
  def prep_stop(:zaq = state), do: Zaq.Application.prep_stop(state)

  @doc "Starts the probe app `app` in `mode` (run inside the peer)."
  def boot(app, mode) do
    spec =
      {:application, app,
       [
         description: ~c"shutdown probe",
         vsn: ~c"0",
         modules: [],
         registered: [],
         applications: [:kernel, :stdlib, :elixir],
         mod: {__MODULE__, mode}
       ]}

    :ok = :application.load(spec)
    {:ok, _} = Application.ensure_all_started(app)
    :ok
  end

  @doc "Records every logger event (as a string) into an Agent (run inside the peer)."
  def capture_logs do
    {:ok, _} = Agent.start(fn -> [] end, name: @log)
    # Keep the peer's stdout quiet; the capture handler below records instead.
    _ = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:shutdown_probe_capture, __MODULE__, %{level: :all})
  end

  def captured, do: Agent.get(@log, & &1)

  # :logger handler callback
  def log(event, _config) do
    Agent.update(@log, &[inspect(event.msg, limit: :infinity) | &1])
  end

  @doc """
  Stops the probe's root supervisor (its children first, like a supervisor giving
  up) and waits for the application master to exit, which happens only after the
  `prep_stop/1` callback has run.
  """
  def stop_root_and_wait(app) do
    master = :application_controller.get_master(app)
    ref = Process.monitor(master)
    :ok = Supervisor.stop(@sup, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^master, _reason} -> :stopped
    after
      5_000 -> {:still_running, app}
    end
  end
end
