defmodule Zaq.Agent.RequestRegistryTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.RequestRegistry

  @table :zaq_agent_request_registry

  setup do
    ensure_registry_available!()

    on_exit(fn ->
      restore_registry!()
    end)

    :ok
  end

  test "get returns not_found for non-binary request ids" do
    assert {:error, :not_found} = RequestRegistry.get(nil)
    assert {:error, :not_found} = RequestRegistry.get(:request_id)
    assert {:error, :not_found} = RequestRegistry.get(123)
  end

  test "delete removes an existing request" do
    request_id = "req-reg-#{System.unique_integer([:positive])}"

    assert :ok = RequestRegistry.put(request_id, %{status: :streaming})
    assert {:ok, %{status: :streaming}} = RequestRegistry.get(request_id)
    assert :ok = RequestRegistry.delete(request_id)
    assert {:error, :not_found} = RequestRegistry.get(request_id)
  end

  test "delete ignores non-binary request ids" do
    assert :ok = RequestRegistry.delete(nil)
    assert :ok = RequestRegistry.delete(:request_id)
    assert :ok = RequestRegistry.delete(123)
  end

  test "get returns not_found when registry table is unavailable" do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    assert {:error, :not_found} = RequestRegistry.get("missing-table-request")
  end

  defp ensure_registry_available! do
    case :ets.whereis(@table) do
      :undefined ->
        restart_or_start_registry()

      _table ->
        :ok
    end
  end

  defp restore_registry! do
    ensure_registry_available!()

    assert_registry_restored!()
  end

  defp restart_or_start_registry do
    case Process.whereis(RequestRegistry) do
      nil ->
        start_registry!()

      pid ->
        restart_registry_process(pid)
    end
  end

  defp restart_registry_process(pid) do
    Process.exit(pid, :kill)
    wait_for_table!(10)
    maybe_start_registry()
  end

  defp maybe_start_registry do
    if :ets.whereis(@table) == :undefined do
      start_registry!()
    end
  end

  defp start_registry! do
    {:ok, _pid} = RequestRegistry.start_link([])
  end

  defp assert_registry_restored! do
    if :ets.whereis(@table) == :undefined do
      flunk("expected request registry ETS table to be restored")
    end
  end

  defp wait_for_table!(0), do: :ok

  defp wait_for_table!(attempts) do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(10)
      wait_for_table!(attempts - 1)
    else
      :ok
    end
  end
end
