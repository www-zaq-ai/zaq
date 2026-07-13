defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialsTabTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Zaq.Engine.Connect.Grant
  alias Zaq.System.AIProviderCredential
  alias ZaqWeb.Live.BO.System.SystemConfig.AICredentialsTab

  test "renders oauth2 auth mode, bearer grant status, and metadata guidance" do
    credential = %AIProviderCredential{
      id: 42,
      name: "OpenAI Codex OAuth2",
      provider: "openai_codex",
      endpoint: "https://chatgpt.com/backend-api",
      metadata: %{
        "auth_kind" => "oauth2",
        "auth_profile" => "openai_chatgpt_codex",
        "audience" => "openai"
      },
      api_key: ""
    }

    grant = %Grant{
      resource_type: "ai_provider_credential",
      resource_id: "42",
      status: "active",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }

    form =
      credential
      |> AIProviderCredential.changeset(%{})
      |> to_form(as: :ai_credential)

    html =
      render_component(&AICredentialsTab.panel/1,
        credentials: [credential],
        ai_grants: [grant],
        form: form,
        modal: true,
        delete_confirm_modal: false,
        action: :edit,
        provider_options: [{"OpenAI Codex", "openai_codex"}]
      )

    assert html =~ "OAuth2"
    assert html =~ "ChatGPT subscription OAuth2"
    refute html =~ "ai-credential-api-key-input"
    assert html =~ "Bearer until"
    assert html =~ "Metadata JSON"
    assert html =~ "provider-specific OAuth2 metadata"
    assert html =~ ~s(&quot;audience&quot;)
    assert html =~ ~s(&quot;openai&quot;)
  end
end
