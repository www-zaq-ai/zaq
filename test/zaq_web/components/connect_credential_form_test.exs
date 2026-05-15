defmodule ZaqWeb.Components.ConnectCredentialFormTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Zaq.Engine.Connect.Credential
  alias ZaqWeb.Components.ConnectCredentialForm

  test "renders oauth2 fields and hides api key input" do
    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "cid"
      })

    form = to_form(changeset, as: :credential)

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "credential[client_id]"
    assert html =~ "credential[client_secret]"
    assert html =~ "credential[scopes]"
    refute html =~ "credential[api_key]"
  end

  test "renders api key input and hides oauth2-only inputs" do
    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive API",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{}
      })

    form = to_form(changeset, as: :credential)

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "credential[api_key]"
    refute html =~ "credential[client_id]"
    refute html =~ "credential[client_secret]"
    refute html =~ "credential[scopes]"
  end

  test "defaults to oauth2 fields when changeset is not provided" do
    form =
      to_form(%{"name" => "Fallback", "provider" => "google_drive", "request_format" => "bearer"},
        as: :credential
      )

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: nil,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "credential[client_id]"
    refute html =~ "credential[api_key]"
  end

  test "renders formatted errors" do
    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "cid"
      })

    form = to_form(changeset, as: :credential)

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        errors: ["Name can't be blank", "Client id can't be blank"],
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "Name can&#39;t be blank"
    assert html =~ "Client id can&#39;t be blank"
  end

  test "shows restore defaults button when default scopes are provided" do
    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "cid"
      })

    form = to_form(changeset, as: :credential)

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal",
        restore_scopes_event: "restore_connect_credential_scopes_defaults",
        default_scopes_text: "scope.one, scope.two"
      )

    assert html =~ "Restore defaults"
  end

  test "renders scopes textarea with list value — filters empty strings and joins" do
    # Use a plain map form so the list with empty string reaches scopes_input_value/1
    # (Ecto changeset casting already strips empty strings from {:array, :string})
    form =
      to_form(%{"scopes" => ["drive.readonly", "", "drive.metadata"]}, as: :credential)

    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "cid"
      })

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "drive.readonly, drive.metadata"
    refute html =~ "drive.readonly, , drive.metadata"
  end

  test "renders scopes textarea with binary value — passes through as-is" do
    # Use a plain map form so the binary value reaches scopes_input_value/1
    form = to_form(%{"scopes" => "drive.readonly, drive.metadata"}, as: :credential)

    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "cid"
      })

    html =
      render_component(&ConnectCredentialForm.credential_form/1,
        form: form,
        changeset: changeset,
        submit_event: "save_connect_credential",
        change_event: "validate_connect_credential",
        cancel_event: "close_connect_credential_modal"
      )

    assert html =~ "drive.readonly, drive.metadata"
  end
end
