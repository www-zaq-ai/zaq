defmodule Zaq.Engine.LinkedDeviceConfirmationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Ecto.Query
  import Zaq.CredentialDocumentFixtures, only: [document: 3]
  import Zaq.AccountsFixtures, only: [super_admin_fixture: 1]
  alias Zaq.ConnectorConfig.Settings
  alias Zaq.Engine.Actions.ConfirmLinkedDevice
  alias Zaq.Engine.ChannelConfig

  setup do
    actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
    other_actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
    %{actor: actor, other_actor: other_actor}
  end

  test "completion derives owner from trusted session authority without revalidating the user", %{
    actor: actor
  } do
    request = request()
    assert {:error, :unauthorized} = ConfirmLinkedDevice.run(%{request: request}, %{actor: actor})

    assert {:error, :unauthorized} =
             ConfirmLinkedDevice.run(
               %{request: Map.put(request, :skip_permissions, true)},
               %{actor: actor, linked_device_runtime: true}
             )

    assert {:ok, saved} = save(Map.put(request, :owner_id, -1), actor)
    assert saved.settings["owner_id"] == actor.user_id

    Zaq.Accounts.get_user!(actor.user_id)
    |> Ecto.Changeset.change(must_change_password: true)
    |> Repo.update!()

    {{:ok, repeated}, queries} = Zaq.QueryRecorder.capture(fn -> save(request, actor) end)
    assert repeated.id == saved.id
    refute Enum.any?(queries, &String.contains?(&1.query, "FROM \"users\""))
  end

  test "parallel duplicate confirmations converge on one connector and one complete batch", %{
    actor: actor
  } do
    request = request()
    count = Repo.aggregate(ChannelConfig, :count)

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> save(request, actor) end) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id
    assert Repo.aggregate(ChannelConfig, :count) == count + 1

    binding = %{
      channel_config_id: first.id,
      credential_id: first.settings["credential_document_id"]
    }

    assert {:ok, "opaque-package-record"} =
             document(binding, :get, %{namespace: "creds", key: "self"})
  end

  test "oversized pairing credentials roll back the connector and its credential", %{actor: actor} do
    request = %{
      request()
      | credentials: %{{"creds", "self"} => String.duplicate("s", 1024 * 1024 + 1)}
    }

    count = Repo.aggregate(ChannelConfig, :count)
    assert {:error, _} = save(request, actor)
    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "confirmation persists every record with one batch mutation after provisioning", %{
    actor: actor
  } do
    records = Map.new(1..20, &{{"creds", to_string(&1)}, "opaque-#{&1}"})
    request = %{request() | credentials: records}
    assert {:ok, config} = save(request, actor)
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
    assert {:ok, ^config} = save(request, actor)
    assert Repo.aggregate(notifications, :count) == 2
  end

  test "provider-specific legacy snapshots are rejected without creating a connector", %{
    actor: actor
  } do
    count = Repo.aggregate(ChannelConfig, :count)

    assert {:error, :invalid_snapshot} =
             save(
               %{
                 attempt_id: Ecto.UUID.generate(),
                 owner_id: 42,
                 identity: %{phone_number: "+15550001", display_name: "Support"},
                 records: %{{"creds", "self"} => "opaque"}
               },
               actor
             )

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "normalized WhatsApp accounts retain phone and name without provider-specific fields", %{
    actor: actor
  } do
    for display_name <- ["Support", nil] do
      request = %{request() | account: %{external_id: "+15550001", display_name: display_name}}
      assert {:ok, config} = save(request, actor)
      assert config.provider == "whatsapp"
      assert config.name == (display_name || "+15550001")

      assert config.settings["account"] == %{
               "external_id" => "+15550001",
               "display_name" => display_name
             }

      refute Map.has_key?(config.settings, "account_identity")
    end
  end

  test "malformed normalized snapshots fail before persistence", %{actor: actor} do
    count = Repo.aggregate(ChannelConfig, :count)
    request = request()

    for invalid <- [
          %{request | attempt_id: "invalid"},
          %{request | provider: ""},
          %{request | provider: String.duplicate("p", 65)},
          %{request | account: %{external_id: ""}},
          %{request | account: %{external_id: String.duplicate("a", 256)}},
          %{request | credentials: %{}},
          Map.delete(request, :credentials)
        ] do
      assert {:error, _} = save(invalid, actor)
    end

    # Owner authority now enters through the Action context, never request fields.
    assert {:error, :unauthorized} = save(request, %{})

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  property "non-string account IDs never reach persistence", %{actor: actor} do
    check all(id <- one_of([integer(), boolean(), constant(nil), list_of(integer())])) do
      assert {:error, :invalid_snapshot} =
               save(%{request() | account: %{external_id: id}}, actor)
    end
  end

  property "request fields and truthy flags cannot supply trusted authorization", %{actor: actor} do
    check all(
            flag <-
              one_of([constant(false), constant(nil), binary(), integer(), list_of(boolean())])
          ) do
      request = Map.merge(request(), %{skip_permissions: true, owner_id: actor.user_id})

      assert {:error, _} =
               Jido.Exec.run(ConfirmLinkedDevice, %{request: request}, %{
                 actor: actor,
                 linked_device_runtime: true,
                 skip_permissions: flag
               })
    end
  end

  test "normalized adapter accounts are saved once and scoped to provider and owner", %{
    actor: actor,
    other_actor: other_actor
  } do
    initial_count = Repo.aggregate(ChannelConfig, :count)

    request = %{
      attempt_id: Ecto.UUID.generate(),
      provider: "telegram",
      owner_id: 42,
      account: %{external_id: "account-7", display_name: "Support"},
      credentials: %{{"credential", "session"} => "opaque"}
    }

    assert {:ok, config} = save(request, actor)
    assert config.provider == "telegram"
    assert config.name == "Support"
    assert config.settings["owner_id"] == actor.user_id
    assert {:ok, replay} = save(request, actor)
    assert replay.id == config.id

    for {changed, operator} <- [
          {%{request | provider: "whatsapp"}, actor},
          {request, other_actor},
          {%{request | account: %{external_id: "account-8", display_name: "Support"}}, actor}
        ] do
      assert {:error, :conflicting_attempt} = save(changed, operator)
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

  test "linked-device confirmation persists the policy and retries retain an explicit later choice",
       %{actor: actor} do
    request = %{request() | account: %{external_id: "+15550001", display_name: "Support"}}

    assert {:ok, saved} = save(request, actor)

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

    assert {:ok, repeated} = save(request, actor)
    assert repeated.id == saved.id
    assert Settings.jido_chat_room_reply_policy(repeated) == :default
  end

  test "confirmation saves defaults and repeated confirmation preserves a later choice", %{
    actor: actor
  } do
    request = %{request() | account: %{external_id: "+15550003"}}

    assert {:ok, saved} = save(request, actor)

    assert saved.settings["jido_chat"]["ingress"] == %{
             "sync_history" => false,
             "sync_full_history" => false
           }

    settings = put_in(saved.settings, ["jido_chat", "ingress", "sync_history"], true)

    saved
    |> ChannelConfig.changeset(%{settings: settings}, adapter_authentication: true)
    |> Repo.update!()

    assert {:ok, repeated} = save(request, actor)
    assert repeated.id == saved.id

    assert repeated.settings["jido_chat"]["ingress"] == %{
             "sync_history" => true,
             "sync_full_history" => false
           }
  end

  defp save(request, actor) do
    case ConfirmLinkedDevice.run(%{request: request}, %{
           actor: actor,
           linked_device_runtime: true,
           skip_permissions: true
         }) do
      {:ok, %{result: result}} -> result
      error -> error
    end
  end
end
