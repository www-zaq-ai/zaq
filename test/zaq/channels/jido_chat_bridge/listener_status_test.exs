defmodule Zaq.Channels.JidoChatBridge.ListenerStatusTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.JidoChatBridge.ListenerStatus

  test "auth_status/2 queries listener processes" do
    pid =
      spawn(fn ->
        receive do
          {:auth_status, from, ref} -> send(from, {ref, :ok})
        end
      end)

    assert {:ok, :ok} = ListenerStatus.auth_status(pid)
  end

  test "auth_status/2 returns error when listener exits" do
    pid =
      spawn(fn ->
        receive do
          {:auth_status, _from, _ref} -> exit({:auth_failed, :invalid_token})
        end
      end)

    assert {:error, {:auth_failed, :invalid_token}} = ListenerStatus.auth_status(pid)
  end

  test "status_from_auth/1 maps known states" do
    assert %{status: :ok} = ListenerStatus.status_from_auth(:ok)
    assert %{status: :pending} = ListenerStatus.status_from_auth(:pending)
    assert %{status: :pending} = ListenerStatus.status_from_auth({:error, :timeout})
  end

  test "status_from_auth/1 delegates non-timeout errors to exit reason mapping" do
    assert %{
             status: :error,
             summary: "Ingress listener authentication failed",
             reason: :invalid_token
           } = ListenerStatus.status_from_auth({:error, {:auth_failed, :invalid_token}})

    assert %{
             status: :error,
             summary: "Ingress listener stopped",
             reason: :unexpected_exit
           } = ListenerStatus.status_from_auth({:error, :unexpected_exit})
  end

  test "status_from_auth/1 maps unrecognized auth statuses to pending unknown" do
    assert %{
             status: :pending,
             summary: "Ingress listener authentication status is unknown"
           } = ListenerStatus.status_from_auth(:unexpected_status)

    assert %{
             status: :pending,
             summary: "Ingress listener authentication status is unknown"
           } = ListenerStatus.status_from_auth({:ok, :not_a_listener_status})
  end

  test "from_exit_reason/1 ignores normal shutdown reasons" do
    assert nil == ListenerStatus.from_exit_reason(:normal)
    assert nil == ListenerStatus.from_exit_reason(:shutdown)
    assert nil == ListenerStatus.from_exit_reason({:shutdown, :supervisor_restart})
  end

  test "from_exit_reason/1 normalizes known jido_chat listener errors" do
    assert %{status: :error, reason: :invalid_token, summary: summary} =
             ListenerStatus.from_exit_reason({:auth_failed, :invalid_token})

    assert summary =~ "authentication failed"

    assert %{status: :error, reason: {:streaming_failed, :closed}, summary: summary} =
             ListenerStatus.from_exit_reason({:transport_failed, {:streaming_failed, :closed}})

    assert summary =~ "connection failed"
  end

  test "query_listener_pids/1 surfaces first non-timeout listener error" do
    listener =
      spawn(fn ->
        receive do
          {:auth_status, _from, _ref} -> exit({:transport_failed, :closed})
        end
      end)

    assert %{
             status: :error,
             summary: "Ingress listener connection failed",
             reason: :closed
           } = ListenerStatus.query_listener_pids([listener])
  end
end
