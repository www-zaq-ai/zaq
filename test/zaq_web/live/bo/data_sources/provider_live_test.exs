defmodule ZaqWeb.Live.BO.DataSources.ProviderLiveTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Repo
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

  test "config modal lifecycle supports new, validate and close" do
    socket =
      socket_with(%{
        provider: "google_drive",
        modal: nil,
        changeset: nil,
        form: nil,
        modal_errors: []
      })

    assert {:noreply, opened} =
             ProviderLive.handle_event("open_modal", %{"action" => "new"}, socket)

    assert opened.assigns.modal == :new
    assert %Ecto.Changeset{} = opened.assigns.changeset

    assert {:noreply, validated} =
             ProviderLive.handle_event(
               "validate",
               %{
                 "form" => %{"name" => "", "provider" => "google_drive", "kind" => "data_source"}
               },
               opened
             )

    assert validated.assigns.changeset.action == :validate
    assert is_list(validated.assigns.modal_errors)

    assert {:noreply, closed} = ProviderLive.handle_event("close_modal", %{}, validated)
    assert closed.assigns.modal == nil
    assert closed.assigns.changeset == nil
  end

  test "open edit modal and delete missing/found configs" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    base_socket =
      socket_with(%{
        provider: "google_drive",
        confirm_delete: nil,
        root_folders_by_config: %{},
        root_folder_meta_by_config: %{},
        stats_errors_by_config: %{},
        modal: nil,
        changeset: nil,
        form: nil,
        modal_errors: []
      })

    assert {:noreply, edited} =
             ProviderLive.handle_event(
               "open_modal",
               %{"action" => "edit", "id" => Integer.to_string(config.id)},
               base_socket
             )

    assert edited.assigns.modal == :edit
    assert %Ecto.Changeset{} = edited.assigns.changeset

    missing_delete_socket = socket_with(Map.put(base_socket.assigns, :confirm_delete, -1))

    assert {:noreply, missing_deleted} =
             ProviderLive.handle_event("delete", %{}, missing_delete_socket)

    assert missing_deleted.assigns.confirm_delete == nil

    existing_delete_socket = socket_with(Map.put(base_socket.assigns, :confirm_delete, config.id))

    assert {:noreply, deleted} = ProviderLive.handle_event("delete", %{}, existing_delete_socket)
    assert deleted.assigns.confirm_delete == nil
    assert Repo.get(ChannelConfig, config.id) == nil
  end

  test "mount initializes provider label and seeded assigns" do
    assert {:ok, mounted} =
             ProviderLive.mount(
               %{"provider" => "custom_provider"},
               %{},
               socket_with(%{service_available: false})
             )

    assert mounted.assigns.provider == "custom_provider"
    assert mounted.assigns.provider_label == "Custom provider"
    assert mounted.assigns.configs == []
    assert mounted.assigns.modal == nil
    assert mounted.assigns.confirm_delete == nil
  end

  test "toggle_enabled, confirm/cancel delete, and capabilities modal events" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-toggle-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{},
        root_folder_meta_by_config: %{},
        stats_errors_by_config: %{}
      })

    assert {:noreply, toggled} =
             ProviderLive.handle_event(
               "toggle_enabled",
               %{"id" => Integer.to_string(config.id)},
               socket
             )

    refute Repo.get!(ChannelConfig, config.id).enabled
    assert toggled.assigns.modal == nil

    assert {:noreply, deleting} =
             ProviderLive.handle_event(
               "confirm_delete",
               %{"id" => Integer.to_string(config.id)},
               toggled
             )

    assert deleting.assigns.confirm_delete == Integer.to_string(config.id)

    assert {:noreply, canceled} = ProviderLive.handle_event("cancel_delete", %{}, deleting)
    assert canceled.assigns.confirm_delete == nil

    assert {:noreply, capabilities_open} =
             ProviderLive.handle_event(
               "open_capabilities",
               %{"id" => Integer.to_string(config.id)},
               canceled
             )

    assert capabilities_open.assigns.capability_modal_config_id == Integer.to_string(config.id)

    assert {:noreply, capabilities_closed} =
             ProviderLive.handle_event("close_capabilities", %{}, capabilities_open)

    assert capabilities_closed.assigns.capability_modal_config_id == nil
  end

  test "folder info modal open/close and fetch_more without cursor" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-folders-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    folder = %Zaq.Contracts.Record{
      id: "folder-1",
      name: "Folder 1",
      kind: :folder,
      permissions: []
    }

    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{config.id => [folder]},
        root_folder_meta_by_config: %{config.id => %{next_page_token: nil}},
        stats_errors_by_config: %{}
      })

    assert {:noreply, with_folder_info} =
             ProviderLive.handle_event(
               "open_folder_info",
               %{"config-id" => Integer.to_string(config.id), "folder-id" => "folder-1"},
               socket
             )

    assert with_folder_info.assigns.folder_info_modal.folder.id == "folder-1"

    assert {:noreply, closed_folder_info} =
             ProviderLive.handle_event("close_folder_info", %{}, with_folder_info)

    assert closed_folder_info.assigns.folder_info_modal == nil

    assert {:noreply, no_more_pages} =
             ProviderLive.handle_event(
               "fetch_more",
               %{"id" => Integer.to_string(config.id)},
               closed_folder_info
             )

    assert no_more_pages.assigns.root_folders_by_config[config.id] == [folder]
  end

  test "open_test populates root folder metadata even on provider errors" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-open-test-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{"connect" => %{"root_selector" => "root", "max_pages" => 1}}
      })
      |> Repo.insert!()

    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{},
        root_folder_meta_by_config: %{},
        stats_errors_by_config: %{}
      })

    assert {:noreply, updated} =
             ProviderLive.handle_event(
               "open_test",
               %{"id" => Integer.to_string(config.id)},
               socket
             )

    assert Map.has_key?(updated.assigns.root_folders_by_config, config.id)
    assert Map.has_key?(updated.assigns.root_folder_meta_by_config, config.id)
    assert is_map(updated.assigns.root_folder_meta_by_config[config.id])
  end

  test "save creates a new data source config" do
    socket =
      socket_with(%{
        provider: "google_drive",
        modal: :new,
        changeset:
          ChannelConfig.changeset(%ChannelConfig{}, %{
            "name" => "placeholder",
            "provider" => "google_drive",
            "kind" => "data_source",
            "enabled" => true,
            "settings" => %{}
          }),
        form: nil,
        modal_errors: [],
        root_folders_by_config: %{},
        root_folder_meta_by_config: %{},
        stats_errors_by_config: %{}
      })

    name = "save-new-#{System.unique_integer([:positive])}"

    assert {:noreply, saved} =
             ProviderLive.handle_event(
               "save",
               %{
                 "form" => %{
                   "name" => name,
                   "provider" => "google_drive",
                   "kind" => "data_source",
                   "enabled" => true,
                   "settings" => %{}
                 }
               },
               socket
             )

    assert saved.assigns.modal == nil
    assert saved.assigns.changeset == nil
    assert Repo.get_by(ChannelConfig, name: name) != nil
  end

  test "save validation error keeps modal open and returns errors" do
    socket =
      socket_with(%{
        provider: "google_drive",
        modal: :new,
        changeset:
          ChannelConfig.changeset(%ChannelConfig{}, %{
            "provider" => "google_drive",
            "kind" => "data_source",
            "enabled" => true,
            "settings" => %{}
          }),
        form: nil,
        modal_errors: []
      })

    assert {:noreply, errored} =
             ProviderLive.handle_event(
               "save",
               %{
                 "form" => %{
                   "name" => "",
                   "provider" => "google_drive",
                   "kind" => "data_source"
                 }
               },
               socket
             )

    assert errored.assigns.modal == :new
    assert %Ecto.Changeset{} = errored.assigns.changeset
    assert errored.assigns.modal_errors != []
  end

  test "validate detects credential provider mismatch" do
    {:ok, mismatch_cred} =
      Connect.create_credential(%{
        "name" => "cred-mismatch-#{System.unique_integer([:positive])}",
        "provider" => "sharepoint",
        "auth_kind" => "oauth2",
        "request_format" => "bearer",
        "user_level" => false,
        "metadata" => %{},
        "client_id" => "client",
        "client_secret" => "secret",
        "scopes" => ["scope.read"]
      })

    socket =
      socket_with(%{
        provider: "google_drive",
        changeset:
          ChannelConfig.changeset(%ChannelConfig{}, %{
            "provider" => "google_drive",
            "kind" => "data_source",
            "enabled" => true,
            "settings" => %{}
          }),
        modal: :new,
        form: nil,
        modal_errors: []
      })

    assert {:noreply, validated} =
             ProviderLive.handle_event(
               "validate",
               %{
                 "form" => %{
                   "name" => "mismatch-test",
                   "provider" => "google_drive",
                   "kind" => "data_source",
                   "enabled" => true,
                   "settings" => %{
                     "connect" => %{"credential_id" => Integer.to_string(mismatch_cred.id)}
                   }
                 }
               },
               socket
             )

    assert validated.assigns.changeset.errors != []

    assert Enum.any?(
             validated.assigns.modal_errors,
             &String.contains?(&1, "provider does not match")
           )
  end

  test "validate detects missing credential" do
    socket =
      socket_with(%{
        provider: "google_drive",
        changeset:
          ChannelConfig.changeset(%ChannelConfig{}, %{
            "provider" => "google_drive",
            "kind" => "data_source",
            "enabled" => true,
            "settings" => %{}
          }),
        modal: :new,
        form: nil,
        modal_errors: []
      })

    assert {:noreply, validated} =
             ProviderLive.handle_event(
               "validate",
               %{
                 "form" => %{
                   "name" => "missing-cred-test",
                   "provider" => "google_drive",
                   "kind" => "data_source",
                   "enabled" => true,
                   "settings" => %{
                     "connect" => %{"credential_id" => "99999999"}
                   }
                 }
               },
               socket
             )

    assert validated.assigns.changeset.errors != []
    assert Enum.any?(validated.assigns.modal_errors, &String.contains?(&1, "not found"))
  end

  test "zaq_local provider uses local_filesystem credential mapping" do
    assert {:ok, mounted} =
             ProviderLive.mount(
               %{"provider" => "zaq_local"},
               %{},
               socket_with(%{service_available: false})
             )

    assert mounted.assigns.provider == "zaq_local"
    assert mounted.assigns.provider_label == "ZAQ Local"

    assert {:noreply, opened} = ProviderLive.handle_event("open_new_credential", %{}, mounted)
    assert opened.assigns.credential_modal

    cred_provider =
      Ecto.Changeset.get_field(opened.assigns.credential_changeset, :provider)

    assert cred_provider == "local_filesystem"
  end

  test "fetch_more with next_page_token attempts to load additional pages" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-cursor-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    folder = %Zaq.Contracts.Record{
      id: "folder-1",
      name: "Folder 1",
      kind: :folder,
      permissions: []
    }

    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{config.id => [folder]},
        root_folder_meta_by_config: %{config.id => %{next_page_token: "token-abc"}},
        stats_errors_by_config: %{}
      })

    assert {:noreply, updated} =
             ProviderLive.handle_event(
               "fetch_more",
               %{"id" => Integer.to_string(config.id)},
               socket
             )

    assert Enum.any?(updated.assigns.root_folders_by_config[config.id], &(&1.id == "folder-1"))
    assert is_map(updated.assigns.root_folder_meta_by_config[config.id])
    assert updated.assigns.stats_errors_by_config[config.id] != nil
  end

  test "open_folder_info handles missing folder gracefully" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-missing-folder-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    actual = %Zaq.Contracts.Record{
      id: "folder-1",
      name: "Folder 1",
      kind: :folder,
      permissions: []
    }

    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{config.id => [actual]}
      })

    assert {:noreply, result} =
             ProviderLive.handle_event(
               "open_folder_info",
               %{"config-id" => Integer.to_string(config.id), "folder-id" => "non-existent"},
               socket
             )

    assert result.assigns.folder_info_modal.config_id == config.id
    assert result.assigns.folder_info_modal.folder == nil
  end

  test "open_folder_info with invalid config-id falls back to -1 key path" do
    socket =
      socket_with(%{
        provider: "google_drive",
        root_folders_by_config: %{
          -1 => [%Zaq.Contracts.Record{id: "fallback", name: "Fallback", kind: :folder}]
        }
      })

    assert {:noreply, result} =
             ProviderLive.handle_event(
               "open_folder_info",
               %{"config-id" => "not-an-int", "folder-id" => "fallback"},
               socket
             )

    assert result.assigns.folder_info_modal.config_id == -1
    assert result.assigns.folder_info_modal.folder.id == "fallback"
  end

  test "mount with service available seeds configs, grants and capability snapshots" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "mounted-cred-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "client",
        client_secret: "secret"
      })

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-mounted-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    {:ok, _grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: Integer.to_string(config.id),
        owner_type: "org",
        status: "active",
        metadata: %{},
        access_token: "tok",
        refresh_token: "ref"
      })

    assert {:ok, mounted} =
             ProviderLive.mount(
               %{"provider" => "google_drive"},
               %{},
               socket_with(%{service_available: true})
             )

    assert Enum.any?(mounted.assigns.configs, &(&1.id == config.id))
    assert mounted.assigns.grants_by_config[config.id]
    assert is_map(mounted.assigns.capabilities_by_config[config.id])
    assert mounted.assigns.root_folders_by_config[config.id] == nil
  end

  test "toggle_enabled re-enables a previously disabled config" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-re-enable-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => false,
        "settings" => %{}
      })
      |> Repo.insert!()

    socket = socket_with(%{provider: "google_drive"})

    assert {:noreply, toggled} =
             ProviderLive.handle_event(
               "toggle_enabled",
               %{"id" => Integer.to_string(config.id)},
               socket
             )

    assert Repo.get!(ChannelConfig, config.id).enabled
    assert toggled.assigns.modal == nil
  end

  test "oauth_claim_state_for_changeset handles changeset and non-changeset args" do
    cs =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        "settings" => %{"connect" => %{"credential_id" => "99"}}
      })

    assert ProviderLive.oauth_claim_state_for_changeset(cs) != nil

    assert ProviderLive.oauth_claim_state_for_changeset(%{}) != nil

    assert ProviderLive.oauth_claim_state_for_changeset(nil) != nil
  end

  test "validate with matching credential provider succeeds without error" do
    {:ok, matching_cred} =
      Connect.create_credential(%{
        "name" => "cred-match-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "auth_kind" => "oauth2",
        "request_format" => "bearer",
        "user_level" => false,
        "metadata" => %{},
        "client_id" => "client",
        "client_secret" => "secret",
        "scopes" => ["scope.read"]
      })

    socket =
      socket_with(%{
        provider: "google_drive",
        changeset:
          ChannelConfig.changeset(%ChannelConfig{}, %{
            "provider" => "google_drive",
            "kind" => "data_source",
            "enabled" => true,
            "settings" => %{}
          }),
        modal: :new,
        form: nil,
        modal_errors: []
      })

    assert {:noreply, validated} =
             ProviderLive.handle_event(
               "validate",
               %{
                 "form" => %{
                   "name" => "matching-cred-test-#{System.unique_integer([:positive])}",
                   "provider" => "google_drive",
                   "kind" => "data_source",
                   "enabled" => true,
                   "settings" => %{
                     "connect" => %{"credential_id" => Integer.to_string(matching_cred.id)}
                   }
                 }
               },
               socket
             )

    refute Enum.any?(validated.assigns.modal_errors, &String.contains?(&1, "does not match"))
    refute Enum.any?(validated.assigns.modal_errors, &String.contains?(&1, "not found"))
  end

  test "delete retains root_folder data for remaining configs via retain_config_keys" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "cfg-delete-retain-#{System.unique_integer([:positive])}",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    socket =
      socket_with(%{
        provider: "google_drive",
        confirm_delete: config.id,
        root_folders_by_config: %{config.id => [%{id: "folder-1", name: "Folder 1"}]},
        root_folder_meta_by_config: %{config.id => %{pages_loaded: 1}},
        stats_errors_by_config: %{config.id => nil}
      })

    assert {:noreply, deleted} = ProviderLive.handle_event("delete", %{}, socket)
    assert deleted.assigns.confirm_delete == nil

    assert deleted.assigns.root_folders_by_config == %{}
    assert deleted.assigns.root_folder_meta_by_config == %{}
    assert deleted.assigns.stats_errors_by_config == %{}
  end
end
