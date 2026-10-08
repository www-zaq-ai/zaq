defmodule ZaqWeb.StudioRuntimeTest do
  use ExUnit.Case, async: false

  alias Zaq.Accounts.{Role, User}
  alias ZaqWeb.StudioRuntime

  setup do
    refute Process.whereis(JidoStudio.Runtime)

    on_exit(fn ->
      Supervisor.terminate_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      Supervisor.delete_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      :telemetry.detach("jido-studio-trace-buffer")
    end)

    %{admin: %User{role: %Role{name: "admin"}}}
  end

  test "Studio is off at boot", %{admin: admin} do
    assert Application.get_env(:jido_studio, :auto_start_runtime) == false
    refute StudioRuntime.running?()
    assert StudioRuntime.authorized?(admin)
    assert :ets.info(:jido_studio_traces) == :undefined
    assert :ets.info(:jido_studio_persistence_docs) == :undefined
  end

  test "starts under the Studio supervisor and repeated starts reuse the runtime", %{admin: admin} do
    assert :ok = StudioRuntime.start(admin)
    pid = Process.whereis(JidoStudio.Runtime)
    assert StudioRuntime.running?()

    assert {JidoStudio.Runtime, ^pid, :supervisor, _} =
             List.keyfind(Supervisor.which_children(JidoStudio.Supervisor), JidoStudio.Runtime, 0)

    assert :ok = StudioRuntime.start(admin)
    assert Process.whereis(JidoStudio.Runtime) == pid
  end

  test "concurrent starts converge on one supervised runtime", %{admin: admin} do
    results =
      1..8
      |> Task.async_stream(fn _ -> StudioRuntime.start(admin) end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert StudioRuntime.running?()
    assert length(Supervisor.which_children(JidoStudio.Supervisor)) == 1
  end

  test "rejects absent and non-admin identities" do
    for user <- [nil, %User{}, %User{role: %Role{name: "staff"}}] do
      refute StudioRuntime.authorized?(user)
      assert {:error, :forbidden} = StudioRuntime.start(user)
    end

    refute StudioRuntime.running?()
  end

  test "super-admins can start Studio" do
    assert :ok = StudioRuntime.start(%User{role: %Role{name: "super_admin"}})
  end

  test "reports startup errors without claiming Studio is running", %{admin: admin} do
    start_supervised!(JidoStudio.TraceBuffer)
    assert {:error, _reason} = StudioRuntime.start(admin)
    refute StudioRuntime.running?()
  end
end
