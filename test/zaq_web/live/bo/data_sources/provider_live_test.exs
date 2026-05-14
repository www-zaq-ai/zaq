defmodule ZaqWeb.Live.BO.DataSources.ProviderLiveTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias ZaqWeb.Live.BO.DataSources.ProviderLive

  defp socket_with(assigns) do
    assigns =
      assigns
      |> Map.put(:__changed__, %{})
      |> Map.put_new(:flash, %{})

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp config_changeset(provider) do
    ChannelConfig.changeset(%ChannelConfig{}, %{
      "name" => "cfg-#{System.unique_integer([:positive])}",
      "provider" => provider,
      "kind" => "data_source",
      "enabled" => true,
      "settings" => %{}
    })
  end

  test "credential modal open/close and validation events" do
    socket =
      socket_with(%{
        provider: "google_drive",
        changeset: config_changeset("google_drive")
      })

    assert {:noreply, opened} = ProviderLive.handle_event("open_new_credential", %{}, socket)
    assert opened.assigns.credential_modal
    assert %Ecto.Changeset{} = opened.assigns.credential_changeset

    assert {:noreply, validated} =
             ProviderLive.handle_event(
               "validate_credential",
               %{"credential" => %{"name" => "", "provider" => "google_drive"}},
               opened
             )

    assert validated.assigns.credential_changeset.action == :validate
    assert is_list(validated.assigns.credential_errors)

    assert {:noreply, closed} =
             ProviderLive.handle_event("close_credential_modal", %{}, validated)

    refute closed.assigns.credential_modal
    assert closed.assigns.credential_changeset == nil
  end

  test "save_credential success stores connect credential id in settings" do
    changeset = config_changeset("google_drive")

    socket =
      socket_with(%{
        provider: "google_drive",
        changeset: changeset,
        kind: :data_source,
        service_available: false
      })

    params = %{
      "name" => "cred-#{System.unique_integer([:positive])}",
      "auth_kind" => "oauth2",
      "client_id" => "client",
      "client_secret" => "secret",
      "scopes" => ["scope.read"]
    }

    assert {:noreply, updated} =
             ProviderLive.handle_event("save_credential", %{"credential" => params}, socket)

    settings = Ecto.Changeset.get_field(updated.assigns.changeset, :settings, %{})
    credential_id = get_in(settings, ["connect", "credential_id"])

    assert is_binary(credential_id)
    assert {:ok, %Credential{id: id}} = Connect.fetch_credential(credential_id)
    assert Integer.to_string(id) == credential_id
    refute updated.assigns.credential_modal
  end

  test "save_credential validation error keeps modal changeset" do
    socket =
      socket_with(%{
        provider: "google_drive",
        changeset: config_changeset("google_drive"),
        kind: :data_source,
        service_available: false
      })

    assert {:noreply, updated} =
             ProviderLive.handle_event(
               "save_credential",
               %{"credential" => %{"provider" => "google_drive"}},
               socket
             )

    assert %Ecto.Changeset{} = updated.assigns.credential_changeset
    assert updated.assigns.credential_errors != []
  end
end
