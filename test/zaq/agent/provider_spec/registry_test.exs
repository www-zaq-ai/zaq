defmodule Zaq.Agent.ProviderSpec.RegistryTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ProviderSpec.Behaviour
  alias Zaq.Agent.ProviderSpec.Providers.{Codex, Default}
  alias Zaq.Agent.ProviderSpec.Registry

  test "selects a static implementation without dynamic module input" do
    assert Registry.fetch("openai_codex") == Codex
    assert Registry.fetch(:openai_codex) == Codex
    assert Registry.fetch("openai") == Default
    assert Registry.fetch("unknown-provider") == Default
    assert Registry.fetch("Elixir.System") == Default
  end

  test "registered implementations satisfy the provider runtime contract" do
    callbacks = Behaviour.behaviour_info(:callbacks)

    for implementation <- Registry.implementations(), {name, arity} <- callbacks do
      assert Code.ensure_loaded?(implementation)
      assert function_exported?(implementation, name, arity)
    end
  end

  test "Codex and default providers translate runtime options independently" do
    context = %{
      provider: "openai_codex",
      runtime_provider: :openai_codex,
      endpoint: nil,
      metadata: %{"authorize_params" => %{"originator" => "zaqos"}},
      auth_kind: "oauth2",
      authentication: %{access_token: "person-token"},
      runtime_identity: %{"chatgpt_account_id" => "acct_person"}
    }

    codex = Codex.put_credential_opts([temperature: 0.3], context)
    assert codex[:access_token] == "person-token"
    assert codex[:base_url] == "https://chatgpt.com/backend-api"
    assert codex[:provider_options][:chatgpt_account_id] == "acct_person"

    default = Default.put_credential_opts([], %{context | provider: "openai"})
    assert default[:api_key] == "person-token"
    refute Keyword.has_key?(default, :provider_options)
  end

  test "Codex removes reserved advanced identity when selected identity is absent" do
    context = %{
      provider: "openai_codex",
      runtime_provider: :openai_codex,
      endpoint: nil,
      metadata: %{},
      auth_kind: "oauth2",
      authentication: %{access_token: "selected-token"},
      runtime_identity: %{}
    }

    opts =
      Codex.put_credential_opts(
        [
          temperature: 0.4,
          api_key: "wrong-key",
          provider_options: [
            auth_mode: :api_key,
            chatgpt_account_id: "wrong-account",
            unrelated: :preserved
          ]
        ],
        context
      )

    assert opts[:temperature] == 0.4
    refute Keyword.has_key?(opts, :api_key)
    assert opts[:access_token] == "selected-token"
    assert opts[:provider_options][:auth_mode] == :oauth
    refute Keyword.has_key?(opts[:provider_options], :chatgpt_account_id)
    assert opts[:provider_options][:unrelated] == :preserved
  end
end
