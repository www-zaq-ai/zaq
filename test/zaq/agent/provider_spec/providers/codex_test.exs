defmodule Zaq.Agent.ProviderSpec.Providers.CodexTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Zaq.Agent.ProviderSpec.Providers.Codex

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        provider: "openai_codex",
        runtime_provider: :openai_codex,
        endpoint: nil,
        metadata: %{},
        auth_kind: "oauth2",
        authentication: %{access_token: "selected-token"},
        runtime_identity: %{}
      },
      Map.new(overrides)
    )
  end

  describe "fixed_url_provider?/1" do
    test "allows configurable endpoints for string and atom providers" do
      assert Codex.fixed_url_provider?("openai_codex") === false
      assert Codex.fixed_url_provider?(:openai_codex) === false
    end
  end

  describe "put_model_spec/2" do
    test "preserves the spec when the endpoint is absent or empty" do
      spec = %{provider: :openai_codex, id: "gpt-5.3-codex-spark", marker: :keep}

      assert Codex.put_model_spec(spec, context(endpoint: nil)) === spec
      assert Codex.put_model_spec(spec, context(endpoint: "")) === spec

      spec_with_base_url = Map.put(spec, :base_url, "https://existing.example")

      assert Codex.put_model_spec(spec_with_base_url, context(endpoint: nil)) ===
               spec_with_base_url

      assert Codex.put_model_spec(spec_with_base_url, context(endpoint: "")) ===
               spec_with_base_url
    end

    test "replaces base_url with a configured endpoint while preserving other fields" do
      spec = %{
        provider: :openai_codex,
        id: "gpt-5.3-codex-spark",
        marker: :keep,
        base_url: "https://existing.example"
      }

      assert Codex.put_model_spec(spec, context(endpoint: "https://custom.example/backend-api")) ===
               %{spec | base_url: "https://custom.example/backend-api"}
    end

    property "configured endpoints replace only base_url" do
      check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 40)) do
        spec = %{
          provider: :openai_codex,
          id: "gpt-5.3-codex-spark",
          marker: suffix,
          base_url: "https://existing.example"
        }

        endpoint = "https://custom.example/#{suffix}"
        result = Codex.put_model_spec(spec, context(endpoint: endpoint))

        assert result.base_url === endpoint
        assert Map.delete(result, :base_url) === Map.delete(spec, :base_url)
      end
    end
  end

  describe "default_advanced_options/1" do
    test "does not inherit generic logprob defaults" do
      assert Codex.default_advanced_options(%{}) === %{}

      assert Codex.default_advanced_options(%{
               provider: "openai_codex",
               supports_logprobs: true
             }) === %{}

      assert Codex.default_advanced_options(%{
               provider: "openai_codex",
               supports_logprobs: false
             }) === %{}
    end
  end

  describe "put_credential_opts/2" do
    for provider_options <- [nil, %{"chatgpt_account_id" => "untrusted"}, "invalid"] do
      test "normalizes #{inspect(provider_options)} provider options" do
        opts =
          Codex.put_credential_opts(
            [
              temperature: 0.4,
              api_key: "stale",
              provider_options: unquote(Macro.escape(provider_options))
            ],
            context()
          )

        assert opts[:temperature] === 0.4
        assert opts[:access_token] === "selected-token"
        assert opts[:auth_mode] === :oauth
        assert opts[:base_url] === "https://chatgpt.com/backend-api"
        refute Keyword.has_key?(opts, :api_key)
        assert opts[:provider_options] === [auth_mode: :oauth]
      end
    end

    test "includes the selected identity and configured originator exactly once" do
      opts =
        Codex.put_credential_opts(
          [
            temperature: 0.4,
            api_key: "stale",
            provider_options: %{"chatgpt_account_id" => "untrusted"}
          ],
          context(
            metadata: %{"authorize_params" => %{"originator" => "zaqos"}},
            runtime_identity: %{"chatgpt_account_id" => "acct_person"}
          )
        )

      assert opts[:temperature] === 0.4
      assert opts[:access_token] === "selected-token"
      assert opts[:auth_mode] === :oauth
      assert opts[:base_url] === "https://chatgpt.com/backend-api"
      refute Keyword.has_key?(opts, :api_key)

      provider_options = Map.new(opts[:provider_options])

      assert provider_options === %{
               auth_mode: :oauth,
               codex_originator: "zaqos",
               chatgpt_account_id: "acct_person"
             }

      assert length(opts[:provider_options]) === 3
    end
  end
end
