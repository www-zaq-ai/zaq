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

  defp record(opts) do
    %Record{id: unique_id(), kind: :file, permissions: Keyword.get(opts, :permissions)}
  end

  defp unique_id, do: "authorization-#{System.unique_integer([:positive])}"
end
