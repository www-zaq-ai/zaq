defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectCredentialEventsTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.ConnectCredentialEvents

  test "close_modal/1 resets credential modal assigns" do
    socket =
      %Socket{
        assigns: %{
          __changed__: %{},
          connect_credential_modal: true,
          connect_credential_changeset: %Changeset{},
          connect_credential_form: %{id: "form"},
          connect_credential_errors: ["oops"],
          connect_default_scopes_text: "openid"
        }
      }

    updated = ConnectCredentialEvents.close_modal(socket)

    refute updated.assigns.connect_credential_modal
    assert is_nil(updated.assigns.connect_credential_changeset)
    assert is_nil(updated.assigns.connect_credential_form)
    assert updated.assigns.connect_credential_errors == []
    assert updated.assigns.connect_default_scopes_text == ""
  end

  test "apply_changeset_with_errors/3 sets form and errors" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    changeset = Map.put(%Changeset{}, :action, :validate)

    updated =
      ConnectCredentialEvents.apply_changeset_with_errors(socket, changeset, fn _ -> ["bad"] end)

    assert updated.assigns.connect_credential_changeset == changeset
    assert updated.assigns.connect_credential_errors == ["bad"]
    assert %Phoenix.HTML.Form{} = updated.assigns.connect_credential_form
  end
end
