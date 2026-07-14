defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialsTabTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [add_error: 3]
  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Zaq.Engine.Connect.Grant
  alias Zaq.System.AIProviderCredential
  alias ZaqWeb.Live.BO.System.SystemConfig.AICredentialsTab

  test "non-Codex oauth2 metadata selects oauth2 mode and keeps api key input" do
    credential = %AIProviderCredential{
      name: "OpenAI OAuth2",
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      metadata: %{"auth_kind" => "oauth2"},
      api_key: ""
    }

    html =
      render_panel(
        form:
          credential
          |> AIProviderCredential.changeset(%{})
          |> to_form(as: :ai_credential),
        modal: true,
        action: :new
      )

    assert html =~ ~s(value="oauth2" selected)
    assert html =~ "OAuth2 uses Connect grants bound to this AI credential."
    assert html =~ "ai-credential-api-key-input"
  end

  test "renders metadata validation errors under metadata json" do
    changeset =
      %AIProviderCredential{}
      |> AIProviderCredential.changeset(%{
        name: "Bad Metadata",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        metadata: "not-json"
      })
      |> add_error(:metadata, "is invalid")
      |> Map.put(:action, :validate)

    html =
      render_panel(
        form: to_form(changeset, as: :ai_credential),
        modal: true,
        action: :new
      )

    assert html =~ "Metadata JSON"
    assert html =~ "not-json"
    assert html =~ "is invalid"
  end

  test "credential rows label oauth2 metadata and revoked grants" do
    credential = %AIProviderCredential{
      id: 101,
      name: "OAuth Anthropic",
      provider: "anthropic",
      endpoint: "https://api.anthropic.com",
      api_key: "",
      metadata: %{"auth_kind" => "oauth2"}
    }

    grant = %Grant{
      resource_type: "ai_provider_credential",
      resource_id: "101",
      status: "revoked",
      expires_at: nil
    }

    html =
      render_panel(
        credentials: [credential],
        ai_grants: [grant],
        modal: false
      )

    assert html =~ "OAuth Anthropic"
    assert html =~ "OAuth2"
    assert html =~ "Grant revoked"
    assert html =~ "text-red-700 bg-red-50 border-red-200"
  end

  test "active grants with nil expiry render active bearer status" do
    credential = %AIProviderCredential{
      id: 202,
      name: "OpenAI Codex Active Grant",
      provider: "openai_codex",
      endpoint: "https://chatgpt.com/backend-api",
      api_key: "",
      metadata: %{"auth_profile" => "openai_chatgpt_codex"}
    }

    grant = %Grant{
      resource_type: "ai_provider_credential",
      resource_id: "202",
      status: "active",
      expires_at: nil
    }

    html =
      render_panel(
        credentials: [credential],
        ai_grants: [grant],
        modal: false,
        provider_options: [{"OpenAI Codex", "openai_codex"}]
      )

    assert html =~ "Bearer grant active"
    assert html =~ "text-emerald-700 bg-emerald-50 border-emerald-200"
  end

  test "nil metadata renders as an empty json object" do
    credential = %AIProviderCredential{
      name: "Nil Metadata",
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      metadata: nil,
      api_key: ""
    }

    html =
      render_panel(
        form:
          credential
          |> AIProviderCredential.changeset(%{})
          |> to_form(as: :ai_credential),
        modal: true,
        action: :new
      )

    assert html =~ "Metadata JSON"
    assert html =~ "{}"
  end

  defp render_panel(assigns) do
    render_component(
      &AICredentialsTab.panel/1,
      Keyword.merge(
        [
          credentials: [],
          ai_grants: [],
          form: empty_form(),
          modal: false,
          delete_confirm_modal: false,
          action: :new,
          provider_options: [{"OpenAI", "openai"}, {"Anthropic", "anthropic"}]
        ],
        assigns
      )
    )
  end

  defp empty_form do
    to_form(%{}, as: :ai_credential)
  end
end
