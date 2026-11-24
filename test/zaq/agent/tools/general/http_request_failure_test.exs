defmodule Zaq.Agent.Tools.General.HttpRequestFailureTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.{ExecutionFailureError, InternalError}
  alias Zaq.Agent.Tools.Registry
  alias Zaq.HttpRequest
  alias Zaq.TestSupport.HttpFaultRouter

  setup do
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    {:ok, reference: Ecto.UUID.generate()}
  end

  for kind <- [:raise, :throw, :exit] do
    @tag failure_kind: kind
    test "confidential #{kind} at the RPC boundary is safe before Jido logs", context do
      %{reference: reference, failure_kind: kind} = context
      sentinel = "private-http-rpc-#{reference}"
      Process.put({HttpFaultRouter, :failure}, {kind, sentinel})
      expected_type = if kind == :raise, do: RuntimeError, else: :unknown

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %ExecutionFailureError{} = error} = execute(reference, true)
          assert error.message == "confidential_http_request_failed"

          assert error.details == %{
                   phase: :execution,
                   reason: :request_failed,
                   exception_type: expected_type,
                   retry: false
                 }

          refute inspect(error) =~ sentinel
        end)

      assert log =~ "phase=execution"
      assert log =~ "exception_type=#{inspect(expected_type)}"
      refute log =~ sentinel
      assert_received {:http_rpc, %{opts: [action: :http_request, confidential: true]}}
      refute_received {:http_rpc, _}

      refute_received {:node_router_event,
                       %{request: %{request: %HttpRequest{doc_reference: ^reference}}}}
    end

    @tag failure_kind: kind
    test "ordinary #{kind} retains Jido's established failure handling", context do
      %{reference: reference, failure_kind: kind} = context
      sentinel = "ordinary-http-rpc-#{reference}"
      Process.put({HttpFaultRouter, :failure}, {kind, sentinel})

      ExUnit.CaptureLog.capture_log(fn ->
        if kind == :raise do
          assert {:error,
                  %ExecutionFailureError{
                    details: %{original_exception: %RuntimeError{message: ^sentinel}}
                  }} = execute(reference, false)
        else
          assert {:error, %InternalError{message: message}} = execute(reference, false)
          assert message =~ "Caught #{kind}:"
          assert message =~ sentinel
        end
      end)

      assert_received {:http_rpc, %{opts: [action: :http_request]}}
      refute_received {:http_rpc, _}

      assert_received {:node_router_event,
                       %{request: %{request: %HttpRequest{doc_reference: ^reference}}}}
    end
  end

  defp execute(reference, confidential?) do
    assert {:ok, [action]} = Registry.resolve_modules(["general.http_request"])

    Jido.Exec.run(
      action,
      %{method: "GET", url: "http://127.0.0.1:1/signed", doc_reference: reference},
      %{node_router: HttpFaultRouter, event_opts: [confidential: confidential?]},
      timeout: 0,
      max_retries: 0,
      log_level: :info
    )
  end
end
