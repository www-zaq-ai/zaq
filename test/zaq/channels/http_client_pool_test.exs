defmodule Zaq.Channels.HttpClient.PoolTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.HttpClient.Pool
  alias Zaq.Channels.HttpClient.Supervisor, as: HttpSupervisor

  @manager __MODULE__.Manager
  @connections __MODULE__.Connections
  @runtime __MODULE__.Runtime
  @url "http://127.0.0.1:1/"

  setup do
    start_supervised!({DynamicSupervisor, name: @runtime, strategy: :one_for_one})
    :ok = HttpSupervisor.ensure_started(runtime_options())

    :ok
  end

  test "HTTP infrastructure is owned by the dynamic runtime and can be recreated after shutdown" do
    [{_, supervisor, :supervisor, [HttpSupervisor]}] = DynamicSupervisor.which_children(@runtime)
    manager = Process.whereis(@manager)
    monitor = Process.monitor(manager)
    :ok = DynamicSupervisor.terminate_child(@runtime, supervisor)
    assert_receive {:DOWN, ^monitor, :process, ^manager, _}, 2_000
    assert Process.whereis(@connections) == nil
    assert :ok = HttpSupervisor.ensure_started(runtime_options())
    refute Process.whereis(@manager) == manager
    assert Pool.with_pool(@url, [], fn _ -> :recreated end, @manager) == :recreated
  end

  test "capacity is finite and borrower death closes the pool before a lease can be reused" do
    owner = self()

    {:ok, borrower} =
      Task.start(fn ->
        Pool.with_pool(
          @url,
          [],
          fn options ->
            send(owner, {:lease, options})

            receive do
              :finish -> :ok
            end
          end,
          @manager
        )
      end)

    assert_receive {:lease, options}, 2_000
    worker = Keyword.fetch!(options, :worker)
    assert worker in Task.Supervisor.children(@connections)
    monitor = Process.monitor(worker)

    assert {:error, %Req.TransportError{reason: :pool_timeout}} =
             Pool.with_pool(
               @url,
               [],
               fn _ -> flunk("saturated pool admitted a request") end,
               @manager
             )

    Process.exit(borrower, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    assert Pool.with_pool(@url, [], fn _ -> :next_request end, @manager) == :next_request
    refute worker in Task.Supervisor.children(@connections)
  end

  test "an unavailable transport fails closed with a classified error" do
    assert {:error, %Req.TransportError{reason: :closed}} =
             Pool.with_pool(
               @url,
               [],
               fn _ -> flunk("unavailable pool must not execute") end,
               __MODULE__.Unavailable
             )
  end

  test "exceptions release resources and each request receives a different pool tag" do
    assert_raise RuntimeError, "fixture failure", fn ->
      Pool.with_pool(@url, [], fn _ -> raise "fixture failure" end, @manager)
    end

    first = Pool.with_pool(@url, [], & &1[:pool_tag], @manager)
    second = Pool.with_pool(@url, [], & &1[:pool_tag], @manager)
    assert {:zaq_http, first_lease, _} = first
    assert {:zaq_http, second_lease, _} = second
    assert is_reference(first_lease)
    assert is_reference(second_lease)
    refute first == second
  end

  defp runtime_options do
    [
      runtime: @runtime,
      supervisor: __MODULE__.Supervisor,
      name: @manager,
      connections: @connections,
      capacity: 1
    ]
  end
end
