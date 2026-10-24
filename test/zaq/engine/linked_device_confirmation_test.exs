defmodule Zaq.Engine.LinkedDeviceConfirmationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Ecto.Query
  import Zaq.CredentialDocumentFixtures, only: [document: 3]
  alias Zaq.ConnectorConfig.Settings
  alias Zaq.Engine.{ChannelConfig, LinkedDeviceConfirmation}

  test "oversized pairing credentials roll back the connector and its credential" do
    request = %{
      request()
      | credentials: %{{"creds", "self"} => String.duplicate("s", 1024 * 1024 + 1)}
    }

    count = Repo.aggregate(ChannelConfig, :count)
    assert {:error, _} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "confirmation persists every record with one batch mutation after provisioning" do
    records = Map.new(1..20, &{{"creds", to_string(&1)}, "opaque-#{&1}"})
    request = %{request() | credentials: records}
    assert {:ok, config} = LinkedDeviceConfirmation.save(request)
    credential_id = config.settings["credential_document_id"]
    binding = %{channel_config_id: config.id, credential_id: credential_id}

    for {{namespace, key}, value} <- records do
      assert {:ok, ^value} =
               document(binding, :get, %{namespace: namespace, key: key})
    end

    notifications =
      from j in Oban.Job,
        where: j.args["credential_id"] == ^credential_id and j.args["kind"] == "grant_replaced"

    # One notification provisions the empty grant, one persists the complete batch.
    assert Repo.aggregate(notifications, :count) == 2
    assert {:ok, ^config} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(notifications, :count) == 2
  end

  test "provider-specific legacy snapshots are rejected without creating a connector" do
    count = Repo.aggregate(ChannelConfig, :count)

    assert {:error, :invalid_snapshot} =
             LinkedDeviceConfirmation.save(%{
               attempt_id: Ecto.UUID.generate(),
               owner_id: 42,
               identity: %{phone_number: "+15550001", display_name: "Support"},
               records: %{{"creds", "self"} => "opaque"}
             })

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "normalized WhatsApp accounts retain phone and name without provider-specific fields" do
    for display_name <- ["Support", nil] do
      request = %{request() | account: %{external_id: "+15550001", display_name: display_name}}
      assert {:ok, config} = LinkedDeviceConfirmation.save(request)
      assert config.provider == "whatsapp"
      assert config.name == (display_name || "+15550001")

      assert config.settings["account"] == %{
               "external_id" => "+15550001",
               "display_name" => display_name
             }

      refute Map.has_key?(config.settings, "account_identity")
    end
  end

  test "malformed normalized snapshots fail before persistence" do
    count = Repo.aggregate(ChannelConfig, :count)
    request = request()

    for invalid <- [
          %{request | attempt_id: "invalid"},
          %{request | provider: ""},
          %{request | provider: String.duplicate("p", 65)},
          %{request | account: %{external_id: ""}},
          %{request | account: %{external_id: String.duplicate("a", 256)}},
          %{request | credentials: %{}},
          Map.delete(request, :credentials),
          Map.delete(request, :owner_id)
        ] do
      assert {:error, _} = LinkedDeviceConfirmation.save(invalid)
    end

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  property "non-string account IDs never reach persistence" do
    check all(id <- one_of([integer(), boolean(), constant(nil), list_of(integer())])) do
      assert {:error, :invalid_snapshot} =
               LinkedDeviceConfirmation.save(%{request() | account: %{external_id: id}})
    end
  end

  test "normalized adapter accounts are saved once and scoped to provider and owner" do
    initial_count = Repo.aggregate(ChannelConfig, :count)

    request = %{
      attempt_id: Ecto.UUID.generate(),
      provider: "telegram",
      owner_id: 42,
      account: %{external_id: "account-7", display_name: "Support"},
      credentials: %{{"credential", "session"} => "opaque"}
    }

    assert {:ok, config} = LinkedDeviceConfirmation.save(request)
    assert config.provider == "telegram"
    assert config.name == "Support"
    assert config.settings["owner_id"] == 42
    assert {:ok, replay} = LinkedDeviceConfirmation.save(request)
    assert replay.id == config.id

    for changed <- [
          %{request | provider: "whatsapp"},
          %{request | owner_id: 43},
          %{request | account: %{external_id: "account-8", display_name: "Support"}}
        ] do
      assert {:error, :conflicting_attempt} = LinkedDeviceConfirmation.save(changed)
    end

    assert Repo.aggregate(ChannelConfig, :count) == initial_count + 1
  end

  defp request do
    %{
      attempt_id: Ecto.UUID.generate(),
      provider: "whatsapp",
      owner_id: 42,
      account: %{external_id: "+15550001", display_name: nil},
      credentials: %{{"creds", "self"} => "opaque-package-record"}
    }
  end

  test "linked-device confirmation persists the policy and retries retain an explicit later choice" do
    request = %{request() | account: %{external_id: "+15550001", display_name: "Support"}}

    assert {:ok, saved} = LinkedDeviceConfirmation.save(request)

    assert Settings.jido_chat_room_reply_policy(Repo.get!(ChannelConfig, saved.id)) ==
             :mention_required

    saved
    |> ChannelConfig.changeset(
      %{
        settings: put_in(saved.settings, ["jido_chat", "room_reply_policy"], "default")
      },
      adapter_authentication: true
    )
    |> Repo.update!()

    assert {:ok, repeated} = LinkedDeviceConfirmation.save(request)
    assert repeated.id == saved.id
    assert Settings.jido_chat_room_reply_policy(repeated) == :default
  end

  test "confirmation saves defaults and repeated confirmation preserves a later choice" do
    request = %{request() | account: %{external_id: "+15550003"}}

    assert {:ok, saved} = LinkedDeviceConfirmation.save(request)

    assert saved.settings["jido_chat"]["ingress"] == %{
             "sync_history" => false,
             "sync_full_history" => false
           }

    settings = put_in(saved.settings, ["jido_chat", "ingress", "sync_history"], true)

    saved
    |> ChannelConfig.changeset(%{settings: settings}, adapter_authentication: true)
    |> Repo.update!()

    assert {:ok, repeated} = LinkedDeviceConfirmation.save(request)
    assert repeated.id == saved.id

    assert repeated.settings["jido_chat"]["ingress"] == %{
             "sync_history" => true,
             "sync_full_history" => false
           }
  end
end
