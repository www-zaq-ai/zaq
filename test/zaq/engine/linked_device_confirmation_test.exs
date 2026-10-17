defmodule Zaq.Engine.LinkedDeviceConfirmationTest do
  use Zaq.DataCase, async: true
  import Ecto.Query
  alias Zaq.Engine.{ChannelConfig, Connect, LinkedDeviceConfirmation}

  test "durable attempt receipt prevents duplicates after response loss" do
    request = request()
    assert {:ok, first} = LinkedDeviceConfirmation.save(request)
    assert {:ok, second} = LinkedDeviceConfirmation.save(request)
    assert first.id == second.id
    assert first.name == "+15550001"
    assert first.settings["credential_document_id"]
  end

  test "oversized pairing credentials roll back the connector and its credential" do
    request = %{
      request()
      | records: %{{"creds", "self"} => String.duplicate("s", 1024 * 1024 + 1)}
    }

    count = Repo.aggregate(ChannelConfig, :count)
    assert {:error, _} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "confirmation persists every record with one batch mutation after provisioning" do
    records = Map.new(1..20, &{{"creds", to_string(&1)}, "opaque-#{&1}"})
    request = %{request() | records: records}
    assert {:ok, config} = LinkedDeviceConfirmation.save(request)
    credential_id = config.settings["credential_document_id"]
    binding = %{channel_config_id: config.id, credential_id: credential_id}

    for {{namespace, key}, value} <- records do
      assert {:ok, ^value} =
               Connect.credential_document(%{
                 op: :get,
                 binding: binding,
                 namespace: namespace,
                 key: key
               })
    end

    notifications =
      from j in Oban.Job,
        where: j.args["credential_id"] == ^credential_id and j.args["kind"] == "grant_replaced"

    # One notification provisions the empty grant, one persists the complete batch.
    assert Repo.aggregate(notifications, :count) == 2
    assert {:ok, ^config} = LinkedDeviceConfirmation.save(request)
    assert Repo.aggregate(notifications, :count) == 2
  end

  test "absent or LID-only phone identity cannot be confirmed" do
    for phone <- [nil, "123456@lid", "not a number", "+", ""] do
      assert {:error, _} =
               LinkedDeviceConfirmation.save(%{request() | identity: %{phone_number: phone}})
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
      identity: %{phone_number: "+15550001", display_name: nil},
      records: %{{"creds", "self"} => "opaque-package-record"}
    }
  end
end
