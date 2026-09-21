defmodule Zaq.System.AIProviderRuntimeResolutionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Zaq.System
  alias Zaq.System.AIProviderCredential

  setup :verify_on_exit!

  defp expect_runtime_event(response) do
    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.request == %{credential_id: 42}
      assert event.next_hop.destination == :engine
      assert event.actor == %{kind: :system, subject: "system-ai-runtime"}
      assert event.opts[:action] == :resolve_ai_runtime_credential
      assert event.opts[:confidential] == true
      %{event | response: response}
    end)
  end

  test "returns an unavailable error when Engine has no credential" do
    expect_runtime_event({:ok, nil})

    assert System.resolve_ai_provider_authentication(
             %AIProviderCredential{id: 42, connect_credential_id: 84},
             node_router_module: Zaq.NodeRouterMock
           ) == {:error, %{credential_id: nil, reason: :credential_unavailable}}
  end

  test "rejects a response with a missing resolved credential" do
    response = {:ok, %{credential: %{id: 42}}}
    expect_runtime_event(response)

    assert System.resolve_ai_provider_authentication(
             %AIProviderCredential{id: 42, connect_credential_id: 84},
             node_router_module: Zaq.NodeRouterMock
           ) == {:error, {:invalid_runtime_credential_response, response}}
  end

  test "rejects an unexpected Engine response" do
    response = :unexpected_response
    expect_runtime_event(response)

    assert System.resolve_ai_provider_authentication(
             %AIProviderCredential{id: 42, connect_credential_id: 84},
             node_router_module: Zaq.NodeRouterMock
           ) == {:error, {:invalid_runtime_credential_response, response}}
  end
end
