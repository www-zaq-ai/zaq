defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.AICredentialEvents

  test "with_provider_endpoint/3 updates endpoint when provider changes" do
    params = %{"provider" => "openai"}

    result =
      AICredentialEvents.with_provider_endpoint(params, "anthropic", fn provider ->
        "https://#{provider}.example"
      end)

    assert result["endpoint"] == "https://openai.example"
  end

  test "with_provider_endpoint/3 returns params unchanged when params is not a map" do
    params = :invalid_params

    result =
      AICredentialEvents.with_provider_endpoint(params, "openai", :not_a_function)

    assert result === params
  end

  test "with_provider_endpoint/3 returns params unchanged when callback arity is invalid" do
    params = %{"provider" => "openai"}

    result =
      AICredentialEvents.with_provider_endpoint(
        params,
        "anthropic",
        fn _, _ -> flunk("should not run") end
      )

    assert result === params
    refute Map.has_key?(result, "endpoint")
  end

  test "save/6 uses update flow for edit action" do
    result =
      AICredentialEvents.save(
        :edit,
        10,
        %{"name" => "n"},
        fn 10 -> %{id: 10} end,
        fn credential, params -> {:ok, {credential.id, params["name"]}} end,
        fn _params -> :should_not_be_called end
      )

    assert result == {:ok, {10, "n"}}
  end

  test "save/6 uses create flow for non-edit action" do
    result =
      AICredentialEvents.save(
        :new,
        nil,
        %{"name" => "n"},
        fn _ -> :should_not_be_called end,
        fn _, _ -> :should_not_be_called end,
        fn params -> {:ok, params["name"]} end
      )

    assert result == {:ok, "n"}
  end

  test "normalize_params/1 parses metadata json and stores OpenAI Codex oauth2 defaults" do
    params = %{
      "provider" => "openai_codex",
      "auth_mode" => "oauth2",
      "api_key" => "ignored-key",
      "metadata" => ~s({"audience":"openai"})
    }

    result = AICredentialEvents.normalize_params(params)

    assert result["provider"] == "openai_codex"
    refute Map.has_key?(result, "api_key")
    assert result["metadata"]["audience"] == "openai"
    assert result["metadata"]["auth_kind"] == "oauth2"
    assert result["metadata"]["auth_profile"] == "openai_chatgpt_codex"
    assert result["metadata"]["authorize_url"] == "https://auth.openai.com/oauth/authorize"
    assert result["metadata"]["scope"] == "openid profile email offline_access"
    assert result["metadata"]["authorize_params"]["id_token_add_organizations"] == "true"
    assert result["metadata"]["authorize_params"]["codex_cli_simplified_flow"] == "true"
    assert result["metadata"]["authorize_params"]["originator"] == "zaqos"
    refute Map.has_key?(result["metadata"], "backend_base_url")
    refute Map.has_key?(result["metadata"], "backend_path")
    refute Map.has_key?(result["metadata"], "redirect_uri")
    refute inspect(result["metadata"]) =~ "localhost:1455"
  end

  test "normalize_params/1 merges missing Codex authorize params into existing metadata" do
    params = %{
      "provider" => "openai_codex",
      "auth_mode" => "oauth2",
      "metadata" =>
        ~s({"authorize_params":{"originator":"custom_originator"},"auth_profile":"openai_chatgpt_codex"})
    }

    result = AICredentialEvents.normalize_params(params)

    assert result["metadata"]["authorize_params"] == %{
             "originator" => "custom_originator",
             "id_token_add_organizations" => "true",
             "codex_cli_simplified_flow" => "true"
           }
  end

  test "normalize_params/1 leaves OpenAI oauth2 metadata generic" do
    params = %{
      "provider" => "openai",
      "auth_mode" => "oauth2",
      "metadata" => ~s({"audience":"openai"})
    }

    result = AICredentialEvents.normalize_params(params)

    assert result["metadata"] == %{"audience" => "openai", "auth_kind" => "oauth2"}
  end

  test "normalize_params/1 forces OpenAI Codex to oauth2" do
    params = %{
      "provider" => "openai_codex",
      "auth_mode" => "api_key",
      "metadata" => "{}"
    }

    result = AICredentialEvents.normalize_params(params)

    assert result["metadata"]["auth_kind"] == "oauth2"
    assert result["metadata"]["auth_profile"] == "openai_chatgpt_codex"
  end

  test "normalize_params/1 clears auth_kind and auth_profile for api key mode" do
    params = %{
      "auth_mode" => "api_key",
      "metadata" =>
        ~s({"auth_kind":"oauth2","auth_profile":"openai_chatgpt_codex","project":"zaq"})
    }

    assert AICredentialEvents.normalize_params(params) == %{
             "metadata" => %{"project" => "zaq"}
           }
  end

  test "normalize_params/1 leaves invalid metadata for changeset validation" do
    params = %{"auth_mode" => "oauth2", "metadata" => "not-json"}

    assert AICredentialEvents.normalize_params(params) == %{
             "metadata" => "not-json"
           }
  end
end
