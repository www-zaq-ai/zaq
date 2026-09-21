defmodule ZaqWeb.Live.People.CredentialsLiveRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Live.People.CredentialsLive

  test "renders literal labels for non-primary credential kinds" do
    assigns = %{
      __changed__: %{},
      flash: %{},
      page_title: "Credentials",
      current_person: %{full_name: "Render Person"},
      person_permissions: MapSet.new([:access_profile]),
      manageable: false,
      credential_modal: nil,
      confirm_action: nil,
      credentials: [
        %{
          credential_id: 41,
          name: "Retained service credential",
          provider: "example",
          auth_kind: "jwt_bearer",
          personal_credential_policy: :disabled,
          status: "revoked",
          expires_at: nil
        }
      ]
    }

    html = rendered_to_string(CredentialsLive.render(assigns))
    document = LazyHTML.from_fragment(html)
    row = LazyHTML.query(document, "#credential-41")

    assert LazyHTML.query(document, "#credential-41 td:nth-child(3)")
           |> LazyHTML.text()
           |> String.trim() == "jwt_bearer"

    assert LazyHTML.text(row) =~ "Revoked"
    assert LazyHTML.text(row) =~ "Disabled"
    assert Enum.empty?(LazyHTML.query(document, "#credential-41 #credential-edit-41"))
    assert Enum.empty?(LazyHTML.query(document, "#credential-41 #credential-revoke-41"))
    assert Enum.empty?(LazyHTML.query(document, "#credential-41 #credential-remove-41"))

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "input[type='password'], input[name='credential[api_key]'], textarea[name^='credential['], select[name^='credential[']"
             )
           )

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "#credential-form-dialog, #credential-revoke-dialog, #credential-remove-dialog"
             )
           )

    assert Enum.empty?(LazyHTML.query(document, "[role='dialog']"))
  end
end
