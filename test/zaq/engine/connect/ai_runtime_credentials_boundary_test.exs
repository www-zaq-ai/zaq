defmodule Zaq.Engine.Connect.AIRuntimeCredentialsBoundaryTest.ProviderSnapshot do
  @fixture_key {Zaq.Engine.Connect.AIRuntimeCredentialsBoundaryTest, :provider_snapshot}

  def get_ai_provider_credential(42) do
    send(self(), {:provider_lookup, 42})
    Process.get(@fixture_key) || raise "provider snapshot fixture is missing"
  end

  def get_ai_provider_credential(id), do: raise("unexpected provider lookup: #{inspect(id)}")
end

defmodule Zaq.Engine.Connect.AIRuntimeCredentialsBoundaryTest.ForbiddenConnect do
  def resolve_credential(_connect_credential_id, _actor) do
    raise "unexpected Connect credential resolution"
  end
end

defmodule Zaq.Engine.Connect.AIRuntimeCredentialsBoundaryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.AIRuntimeCredentials
  alias Zaq.System.AIProviderCredential

  @actor %{kind: :system, subject: "ai-runtime-credentials-boundary-test"}
  @fixture_key {__MODULE__, :provider_snapshot}

  test "rejects a provider snapshot without a canonical Connect association" do
    provider = provider_snapshot(nil)

    with_provider(provider, fn ->
      assert AIRuntimeCredentials.resolve(42, @actor,
               system_module: __MODULE__.ProviderSnapshot,
               connect_module: __MODULE__.ForbiddenConnect
             ) == {:error, %{credential_id: nil, reason: :credential_unavailable}}

      assert_received {:provider_lookup, 42}
    end)
  end

  property "noninteger association snapshots never resolve authentication" do
    association_generator =
      one_of([
        constant(nil),
        string(:alphanumeric, min_length: 0, max_length: 32),
        member_of([true, false, :invalid]),
        member_of([0.0, 84.5]),
        constant([]),
        constant(%{})
      ])

    assert_noninteger_association("84")

    check all(connect_credential_id <- association_generator, max_runs: 30) do
      provider = provider_snapshot(connect_credential_id)

      with_provider(provider, fn ->
        assert AIRuntimeCredentials.resolve(42, @actor,
                 system_module: __MODULE__.ProviderSnapshot,
                 connect_module: __MODULE__.ForbiddenConnect
               ) == {:error, %{credential_id: nil, reason: :credential_unavailable}}

        assert_received {:provider_lookup, 42}
      end)
    end
  end

  defp assert_noninteger_association(connect_credential_id) do
    provider = provider_snapshot(connect_credential_id)

    with_provider(provider, fn ->
      assert AIRuntimeCredentials.resolve(42, @actor,
               system_module: __MODULE__.ProviderSnapshot,
               connect_module: __MODULE__.ForbiddenConnect
             ) == {:error, %{credential_id: nil, reason: :credential_unavailable}}

      assert_received {:provider_lookup, 42}
    end)
  end

  defp provider_snapshot(connect_credential_id) do
    %AIProviderCredential{
      id: 42,
      name: "Unassociated provider snapshot",
      provider: "openai",
      endpoint: "https://runtime.example.com/v1",
      connect_credential_id: connect_credential_id,
      api_key: "legacy-key-must-not-be-used",
      metadata: %{"auth_kind" => "api_key"},
      sovereign: false
    }
  end

  defp with_provider(provider, fun) do
    previous = Process.get(@fixture_key, :absent)
    Process.put(@fixture_key, provider)

    try do
      fun.()
    after
      case previous do
        :absent -> Process.delete(@fixture_key)
        previous -> Process.put(@fixture_key, previous)
      end
    end
  end
end
