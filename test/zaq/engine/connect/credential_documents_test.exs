defmodule Zaq.Engine.Connect.CredentialDocumentsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.CredentialDocumentFixtures

  alias Zaq.Engine.Actions.CredentialDocument
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Event
  alias Zaq.NodeRouter

  setup do
    %{binding: credential_document_fixture()}
  end

  property "binary records round-trip through the real routed operation", %{binding: binding} do
    check all(value <- binary(max_length: 4096), max_runs: 20) do
      assert :ok = request(binding, :put, %{namespace: "creds", key: "self", value: value})
      assert {:ok, ^value} = request(binding, :get, %{namespace: "creds", key: "self"})
    end
  end

  property "batched binary records round-trip without replacing unrelated records", %{
    binding: binding
  } do
    assert :ok = put(binding, "untouched", "key", "kept")

    check all(
            values <-
              map_of(string(:alphanumeric, min_length: 1), binary(max_length: 1024),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 20
          ) do
      records = Map.new(values, fn {key, value} -> {{"batch", key}, value} end)
      assert :ok = request(binding, :put_many, %{records: records})

      for {key, value} <- values, do: assert({:ok, ^value} = get(binding, "batch", key))
      assert {:ok, "kept"} = get(binding, "untouched", "key")
    end
  end

  test "a batch emits one mutation and identical batches are silent", %{binding: binding} do
    records = %{{"a", "one"} => "first", {"b", "two"} => "second"}
    count = Repo.aggregate(Oban.Job, :count)
    assert :ok = request(binding, :put_many, %{records: records})
    assert Repo.aggregate(Oban.Job, :count) == count + 1
    assert :ok = request(binding, :put_many, %{records: records})
    assert Repo.aggregate(Oban.Job, :count) == count + 1
    assert :ok = request(binding, :put_many, %{records: %{}})
    assert Repo.aggregate(Oban.Job, :count) == count + 1
  end

  test "invalid batches and outer rollback preserve existing records", %{binding: binding} do
    assert :ok = put(binding, "a", "key", "original")

    for invalid <- [
          %{{"", "key"} => "bad"},
          %{{"a", "key"} => :not_binary},
          %{"malformed" => "bad"},
          %{{"a", "large"} => :binary.copy("x", 1_048_577)}
        ] do
      records = Map.put(invalid, {"a", "new"}, "must-not-persist")
      assert {:error, :invalid_request} = request(binding, :put_many, %{records: records})
      assert :error = get(binding, "a", "new")
      assert {:ok, "original"} = get(binding, "a", "key")
    end

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert :ok =
                        Connect.credential_document(%{
                          op: :put_many,
                          binding: binding,
                          records: %{{"a", "key"} => "replacement", {"a", "new"} => "new"}
                        })

               Repo.rollback(:rollback)
             end)

    assert {:ok, "original"} = get(binding, "a", "key")
    assert :error = get(binding, "a", "new")
  end

  test "namespaces and connector bindings are independent", %{binding: binding} do
    other = credential_document_fixture()
    assert :ok = put(binding, "a", "key", "one")
    assert :ok = put(binding, "b", "key", "two")
    assert :ok = put(other, "a", "key", "other")
    assert {:ok, ["key"]} = request(binding, :list_keys, %{namespace: "a"})
    assert :ok = request(binding, :delete, %{namespace: "a", key: "key"})
    assert :error = get(binding, "a", "key")
    assert {:ok, "two"} = get(binding, "b", "key")
    assert :ok = request(binding, :clear)
    assert {:ok, []} = request(binding, :list_keys, %{namespace: "b"})
    assert {:ok, "other"} = get(other, "a", "key")

    forged = %{binding | credential_id: other.credential_id}
    assert {:error, :invalid_binding} = request(forged, :clear)
    assert {:ok, "other"} = get(other, "a", "key")
  end

  test "routed document contents are excluded from observer broadcasts", %{binding: binding} do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    assert :ok = put(binding, "private", "key", "private-value")
    assert {:ok, "private-value"} = get(binding, "private", "key")
    refute_received {:node_router_event, %Event{request: %{binding: ^binding}}}
  end

  test "namespace removal is scoped, atomic with its caller and idempotent", %{binding: binding} do
    assert :ok = put(binding, "session", "one", "state")
    assert :ok = put(binding, "session", "two", "state")
    assert :ok = put(binding, "creds", "self", "paired")

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert :ok =
                        Connect.credential_document(%{
                          op: :delete_namespace,
                          binding: binding,
                          namespace: "session"
                        })

               Repo.rollback(:rollback)
             end)

    assert {:ok, ["one", "two"]} = request(binding, :list_keys, %{namespace: "session"})
    assert :ok = request(binding, :delete_namespace, %{namespace: "session"})
    assert {:ok, []} = request(binding, :list_keys, %{namespace: "session"})
    assert {:ok, "paired"} = get(binding, "creds", "self")
    count = Repo.aggregate(Oban.Job, :count)
    assert :ok = request(binding, :delete_namespace, %{namespace: "session"})
    assert Repo.aggregate(Oban.Job, :count) == count
    assert {:error, :invalid_request} = request(binding, :delete_namespace, %{namespace: ""})
  end

  test "only explicit confidential synchronous runtime events authorize access", %{
    binding: binding
  } do
    payload = %{binding: binding, op: :clear}

    for opts <- [[], [confidential: true], [credential_document_runtime: true]] do
      event = Event.new(payload, :engine, opts: opts)

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :credential_document, nil)
    end

    for {destination, type} <- [{:engine, :async}, {:channels, :sync}] do
      event = Event.new(payload, destination, type: type, opts: runtime_opts())

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :credential_document, nil)
    end

    assert {:error, _} = Jido.Exec.run(CredentialDocument, %{request: payload}, %{})
    assert {:error, :invalid_request} = request(binding, :unknown)
    assert {:error, :invalid_request} = request(binding, :put, %{namespace: "a", key: "b"})
  end

  test "disabled and archived connectors fail closed without losing state", %{binding: binding} do
    assert :ok = put(binding, "session", "peer", "kept")
    config = Repo.get!(ChannelConfig, binding.channel_config_id)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = get(binding, "session", "peer")
    assert {:error, :connector_unavailable} = put(binding, "session", "peer", "lost")

    assert {:error, :connector_unavailable} =
             request(binding, :put_many, %{records: %{{"session", "peer"} => "lost"}})

    Repo.update!(Ecto.Changeset.change(disabled, enabled: true))
    assert {:ok, "kept"} = get(binding, "session", "peer")
    assert {:ok, _} = ChannelConfig.archive(config)
    assert {:error, :connector_unavailable} = request(binding, :clear)
  end

  test "revoked and missing grants are never recreated by writes", %{binding: binding} do
    assert {:ok, _} = Connect.revoke_credential_grant(binding.credential_id, :org)

    assert {:error, :credential_revoked} =
             request(binding, :put_many, %{records: %{{"a", "key"} => "lost"}})

    assert {:error, :credential_revoked} = put(binding, "a", "b", "new")
    assert Repo.get_by!(Grant, credential_id: binding.credential_id).status == "revoked"
    assert {:ok, _} = Connect.remove_credential_grant(binding.credential_id, :org)
    assert {:error, :global_credential_missing} = request(binding, :clear)
    refute Repo.get_by(Grant, credential_id: binding.credential_id)
  end

  test "corrupt document and unreadable ciphertext are distinct from missing records", %{
    binding: binding
  } do
    for document <- [
          "invalid",
          ~s({"version":2,"records":{}}),
          ~s({"version":1,"records":{"a":{"b":"not base64"}}})
        ] do
      assert {:ok, _} =
               Connect.replace_credential_grant(binding.credential_id, :org, %{api_key: document})

      assert {:error, :corrupt_document} = get(binding, "a", "b")
      assert {:error, :corrupt_document} = request(binding, :clear)
    end

    Repo.query!("UPDATE connect_grants SET api_key = $1 WHERE credential_id = $2", [
      "enc:invalid",
      binding.credential_id
    ])

    assert {:error, :credential_unavailable} = get(binding, "a", "b")
  end

  test "no-op operations do not enqueue notifications and writes preserve expiry", %{
    binding: binding
  } do
    expires = DateTime.add(DateTime.utc_now(:second), 3600)

    assert {:ok, _} =
             Connect.replace_credential_grant(binding.credential_id, :org, %{
               api_key: ~s({"version":1,"records":{}}),
               expires_at: expires
             })

    assert :ok = put(binding, "a", "b", "kept")
    count = Repo.aggregate(Oban.Job, :count)
    assert :ok = put(binding, "a", "b", "kept")
    assert :ok = request(binding, :delete, %{namespace: "a", key: "missing"})
    assert Repo.aggregate(Oban.Job, :count) == count
    assert Repo.get_by!(Grant, credential_id: binding.credential_id).expires_at == expires
  end

  test "invalid and oversized writes leave previous records intact", %{binding: binding} do
    assert :ok = put(binding, "a", "b", "kept")
    assert {:error, :invalid_request} = put(binding, <<255>>, "b", "value")
    assert {:error, :invalid_request} = put(binding, "a", "b", String.duplicate("x", 1_048_577))
    assert {:ok, "kept"} = get(binding, "a", "b")
  end

  test "expired grant cannot be read or extended by a record write", %{binding: binding} do
    grant = Repo.get_by!(Grant, credential_id: binding.credential_id)
    expired_at = DateTime.add(DateTime.utc_now(:second), -1)
    Repo.update!(Ecto.Changeset.change(grant, expires_at: expired_at))
    assert {:error, :credential_expired} = get(binding, "a", "b")
    assert {:error, :credential_expired} = put(binding, "a", "b", "new")
    assert Repo.get!(Grant, grant.id).expires_at == expired_at
  end

  test "stored binding must match both sides and document credential mode", %{binding: binding} do
    config = Repo.get!(ChannelConfig, binding.channel_config_id)
    Repo.update!(Ecto.Changeset.change(config, settings: %{}))
    assert {:error, :invalid_binding} = request(binding, :clear)
    Repo.update!(Ecto.Changeset.change(Repo.reload!(config), settings: config.settings))

    credential = Connect.get_credential!(binding.credential_id)

    for attrs <- [
          %{metadata: %{}},
          %{
            metadata: %{
              "auth_profile_id" => "credential_document_v1",
              "subject" => "channel_config:0"
            }
          },
          %{provider: "another"},
          %{personal_credential_policy: :optional},
          %{secret_binding: :configuration}
        ] do
      changed = Repo.update!(Ecto.Changeset.change(credential, attrs))
      assert {:error, :invalid_binding} = request(binding, :clear)
      Repo.update!(Ecto.Changeset.change(changed, Map.take(credential, Map.keys(attrs))))
    end
  end

  test "document capacity failure is atomic", %{binding: binding} do
    value = :binary.copy(<<255>>, 1_048_576)
    records = Map.new(1..11, &{to_string(&1), Base.encode64(value)})
    document = Jason.encode!(%{version: 1, records: %{session: records}})

    assert {:ok, _} =
             Connect.replace_credential_grant(binding.credential_id, :org, %{api_key: document})

    assert {:error, :document_too_large} = put(binding, "session", "12", value)

    assert {:error, :document_too_large} =
             request(binding, :put_many, %{
               records: %{{"session", "12"} => value, {"other", "new"} => "new"}
             })

    assert :error = get(binding, "other", "new")
    assert :error = get(binding, "session", "12")
    assert {:ok, ^value} = get(binding, "session", "1")
  end

  defp put(binding, namespace, key, value),
    do: request(binding, :put, %{namespace: namespace, key: key, value: value})

  defp get(binding, namespace, key), do: request(binding, :get, %{namespace: namespace, key: key})

  defp request(binding, op, fields \\ %{}) do
    fields
    |> Map.merge(%{binding: binding, op: op})
    |> Event.new(:engine, opts: [{:action, :credential_document} | runtime_opts()])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp runtime_opts, do: [confidential: true, credential_document_runtime: true]
end
