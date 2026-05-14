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

  test "service unavailable ignores unknown events" do
    socket = socket_with(%{service_available: false, provider: "google_drive"})

    assert {:noreply, same_socket} =
             ProviderLive.handle_event("unknown_event", %{"any" => "value"}, socket)

    assert same_socket.assigns.service_available == false
  end

  test "oauth claim modal events open, block, complete and close" do
    socket =
      socket_with(%{
        oauth_claim_modal: false,
        oauth_claim_url: nil,
        flash: %{}
      })

    assert {:noreply, opened} =
             ProviderLive.handle_event(
               "open_oauth_claim",
               %{"url" => "https://example.test/auth"},
               socket
             )

    assert opened.assigns.oauth_claim_modal
    assert opened.assigns.oauth_claim_url == "https://example.test/auth"

    assert {:noreply, blocked} = ProviderLive.handle_event("oauth_popup_blocked", %{}, opened)
    refute blocked.assigns.oauth_claim_modal
    assert blocked.assigns.oauth_claim_url == nil

    assert {:noreply, completed} = ProviderLive.handle_event("oauth_popup_result", %{}, blocked)
    refute completed.assigns.oauth_claim_modal
    assert completed.assigns.oauth_claim_url == nil

    assert {:noreply, closed} = ProviderLive.handle_event("close_oauth_claim", %{}, completed)
    refute closed.assigns.oauth_claim_modal
  end

  test "folder and capability helpers handle edge cases" do
    config_a = %ChannelConfig{id: 10, name: "Config A"}
    config_b = %ChannelConfig{id: 11, name: "Config B"}

    assert ProviderLive.active_grant_for_config(config_a, %{10 => %{id: 99}}) == %{id: 99}
    assert ProviderLive.active_grant_for_config(config_b, %{10 => %{id: 99}}) == nil

    assert ProviderLive.capabilities_modal_open?("10", 10)
    refute ProviderLive.capabilities_modal_open?("10", 11)

    modal_capabilities =
      ProviderLive.capabilities_for_modal(config_a, %{
        10 => %{
          labels: %{"files.read" => "Files Read", "folders.write" => "Folders Write"},
          required: ["folders.write", "files.read"],
          resolved: %{"files.read" => true}
        }
      })

    assert modal_capabilities == [
             %{label: "Files Read", supported?: true},
             %{label: "Folders Write", supported?: false}
           ]

    assert ProviderLive.selected_config([config_a, config_b], "11").name == "Config B"
    assert ProviderLive.selected_config([config_a], "missing") == nil
  end

  test "folder info helpers normalize missing values" do
    assert ProviderLive.root_folders(nil) == []
    assert ProviderLive.root_folders([%{id: "1"}]) == [%{id: "1"}]
    assert ProviderLive.root_folders(%{}) == []

    assert ProviderLive.folder_name(%{name: "Team Folder", id: "f-1"}) == "Team Folder"
    assert ProviderLive.folder_name(%{name: "", id: "fallback-id"}) == "fallback-id"
    assert ProviderLive.folder_name(%{name: "", id: ""}) == "Unnamed"

    assert ProviderLive.folder_icon(%{icon: "icon-folder"}) == "icon-folder"
    assert ProviderLive.folder_icon(%{}) == nil

    assert ProviderLive.folder_url(%{url: "https://example.test/folders/1"}) ==
             "https://example.test/folders/1"

    assert ProviderLive.folder_url(%{}) == nil

    assert ProviderLive.selected_folder_info(%{folder: %{id: "1"}}) == %{id: "1"}
    assert ProviderLive.selected_folder_info(nil) == nil

    assert ProviderLive.folder_permissions(%{permissions: [%{id: "perm-1"}]}) == [%{id: "perm-1"}]
    assert ProviderLive.folder_permissions(%{}) == []

    assert ProviderLive.permission_label(%{name: "Writer"}) == "Writer"
    assert ProviderLive.permission_label(%{id: "perm-id"}) == "perm-id"
    assert ProviderLive.permission_label(%{}) == "Unknown permission"
  end

  test "changeset helpers expose credential and root selector defaults" do
    with_connect =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        "settings" => %{"connect" => %{"credential_id" => "123", "root_selector" => "alpha"}}
      })

    assert ProviderLive.connect_credential_id_from_changeset(with_connect) == "123"
    assert ProviderLive.root_selector_from_changeset(with_connect, "google_drive") == "alpha"

    empty = ChannelConfig.changeset(%ChannelConfig{}, %{"settings" => %{}})

    assert ProviderLive.connect_credential_id_from_changeset(empty) == ""
    assert ProviderLive.root_selector_from_changeset(empty, "google_drive") == "root"
    assert ProviderLive.root_selector_from_changeset(empty, "sharepoint") == "/"
  end
end
