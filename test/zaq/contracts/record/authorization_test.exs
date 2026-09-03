defmodule Zaq.Contracts.Record.AuthorizationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Authorization

  describe "can?/3" do
    test "returns false when permissions are not a list" do
      person = create_person()

      refute Authorization.can?(actor(person), record(permissions: nil), :read)
    end

    test "ignores malformed entries in a permissions list" do
      person = create_person()

      refute Authorization.can?(
               actor(person),
               record(permissions: [nil, %{unexpected: "value"}]),
               :read
             )
    end

    test "matches a non-email principal against a person channel" do
      person = create_person()
      add_channel(person.id, "mattermost", " User-42 ")

      permissions = [
        permission(%{
          "principal" => %{"channel" => " MATTERMOST ", "identifier" => " user-42 "},
          "access_rights" => ["read"]
        })
      ]

      assert Authorization.can?(actor(person), record(permissions: permissions), :read)
    end

    test "accepts a person that already has channels loaded" do
      person = create_person()
      add_channel(person.id, "mattermost", " User-42 ")
      person = People.get_person_with_channels(person.id)

      permissions = [
        permission(%{
          "principal" => %{"channel" => "mattermost", "identifier" => "user-42"},
          "access_rights" => ["read"]
        })
      ]

      assert Authorization.can?(person, record(permissions: permissions), :read)
    end

    test "filters authorized records while preserving order" do
      person = create_person()

      records = [
        record(id: "file-1", permissions: [permission_for(person.email, ["read"])]),
        record(id: "file-2", permissions: [permission_for("other@example.com", ["read"])]),
        record(id: "file-3", permissions: [permission_for(person.email, ["edit"])]),
        record(id: "file-4", permissions: [permission_for(person.email, ["read"])]),
        record(id: "file-5", permissions: nil)
      ]

      assert Enum.map(Authorization.filter(actor(person), records, :read), & &1.id) == [
               "file-1",
               "file-4"
             ]
    end

    test "returns an empty list when filtering cannot resolve a person" do
      records = [record(permissions: [permission_for("user@example.com", ["read"])])]

      assert Authorization.filter(nil, records, :read) == []
      assert Authorization.filter(%{person: %{id: "missing"}}, records, :read) == []
    end

    test "loads a person once when filtering multiple records" do
      person = create_person()

      records =
        for index <- 1..5 do
          record(id: "file-#{index}", permissions: [permission_for(person.email, ["read"])])
        end

      {authorized_records, queries} =
        capture_person_lookup_queries(fn ->
          Authorization.filter(actor(person), records, :read)
        end)

      assert length(authorized_records) == 5

      assert Enum.frequencies_by(queries, & &1.source) == %{
               "channels" => 1,
               "people" => 1
             }
    end

    test "supports the legacy flat principal representation" do
      person = create_person()
      add_channel(person.id, "slack", "slack-user-42")

      permissions = [
        permission(%{
          "principal_type" => "slack",
          "principal_key" => "slack-user-42",
          "access_rights" => ["read"]
        })
      ]

      assert Authorization.can?(actor(person), record(permissions: permissions), :read)
    end

    test "rejects a permission with no usable principal" do
      person = create_person()
      permissions = [permission(%{"access_rights" => ["read"]})]

      refute Authorization.can?(actor(person), record(permissions: permissions), :read)
    end

    test "recognizes move and discards unknown access rights" do
      person = create_person()

      permissions = [
        permission(%{
          "principal" => %{"channel" => "email", "identifier" => person.email},
          "access_rights" => ["move", "share"]
        })
      ]

      assert Authorization.can?(actor(person), record(permissions: permissions), :move)
      refute Authorization.can?(actor(person), record(permissions: permissions), :delete)
    end

    test "falls back to an email channel when the canonical email is nil" do
      person = create_person(%{email: nil})
      add_channel(person.id, "email", "fallback@example.com")

      permissions = [
        permission(%{
          "principal" => %{"channel" => "email", "identifier" => "fallback@example.com"},
          "access_rights" => ["read"]
        })
      ]

      assert Authorization.can?(actor(person), record(permissions: permissions), :read)
    end
  end

  defp create_person(overrides \\ %{}) do
    id = unique_id()

    {:ok, person} =
      People.create_person(
        Map.merge(%{full_name: "Authorization Test #{id}", email: "#{id}@example.com"}, overrides)
      )

    person
  end

  defp add_channel(person_id, platform, identifier) do
    {:ok, channel} =
      People.add_channel(%{
        "person_id" => person_id,
        "platform" => platform,
        "channel_identifier" => identifier
      })

    channel
  end

  defp actor(person), do: %{person: %{id: person.id}}

  defp permission(attrs), do: %Record{id: unique_id(), kind: :permission, attributes: attrs}

  defp permission_for(email, rights) do
    permission(%{
      "principal" => %{"channel" => "email", "identifier" => email},
      "access_rights" => rights
    })
  end

  defp record(opts) do
    %Record{
      id: Keyword.get(opts, :id, unique_id()),
      kind: :file,
      permissions: Keyword.get(opts, :permissions)
    }
  end

  defp capture_person_lookup_queries(fun) do
    handler_id = {__MODULE__, :person_lookup_queries, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:zaq, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] in ["people", "channels"] do
            send(
              test_pid,
              {:person_lookup_query, %{source: metadata[:source], query: metadata[:query]}}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_person_lookup_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_person_lookup_queries(queries) do
    receive do
      {:person_lookup_query, query} ->
        collect_person_lookup_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp unique_id, do: "authorization-#{System.unique_integer([:positive])}"
end
