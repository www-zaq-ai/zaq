defmodule Zaq.Accounts.PeoplePermissionsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, PeoplePermissionGrant, PeoplePermissions, Person, Team}

  setup do
    Repo.delete_all(PeoplePermissionGrant)
    {:ok, person} = People.create_person(%{full_name: "Permission person"})
    {:ok, a} = People.create_team(%{name: "Permission A"})
    {:ok, b} = People.create_team(%{name: "Permission B"})
    %{person: person, a: a, b: b}
  end

  test "default deny and invalid identities remain denied even with global grants", %{
    person: person
  } do
    assert PeoplePermissions.effective_permissions(person) == MapSet.new()
    assert {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)

    for invalid <- [
          nil,
          123,
          %{},
          %Person{},
          %Person{id: person.id},
          %{person | id: nil},
          %{person | id: -1},
          %{person | team_ids: nil}
        ] do
      assert PeoplePermissions.effective_permissions(invalid) == MapSet.new()
      refute PeoplePermissions.allowed?(invalid, :access_profile)
      refute PeoplePermissions.allowed?(invalid, [:access_profile])
    end

    assert PeoplePermissions.allowed?(person, :access_profile)
    refute PeoplePermissions.allowed?(person, :unknown)
    refute PeoplePermissions.allowed?(person, "unknown")
    assert PeoplePermissions.allowed?(%{person | status: "inactive"}, :access_profile)
  end

  test "global and supplied current teams union without implicit prerequisites", %{
    person: p,
    a: a,
    b: b
  } do
    assert {:ok, _} = PeoplePermissions.grant({:team, a.id}, :share_conversations)
    assert {:ok, _} = PeoplePermissions.grant({:team, b.id}, :access_message_history)
    p = %{p | team_ids: [a.id, b.id]}
    assert PeoplePermissions.allowed?(p, :share_conversations)
    assert PeoplePermissions.allowed?(%{p | team_ids: [a.id]}, [:share_conversations])
    history = [:access_profile, :access_message_history]
    sharing = history ++ [:share_conversations]
    refute PeoplePermissions.allowed?(p, history)
    refute PeoplePermissions.allowed?(p, sharing)
    assert {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    assert PeoplePermissions.allowed?(p, history)
    assert PeoplePermissions.allowed?(p, sharing)
    assert {:ok, _} = PeoplePermissions.grant({:team, a.id}, :access_profile)
    assert {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
    assert PeoplePermissions.allowed?(p, sharing)
    refute PeoplePermissions.allowed?(%{p | team_ids: [b.id]}, :access_profile)
    assert {:ok, _} = People.delete_team(a)
    assert PeoplePermissions.effective_permissions(p) == MapSet.new([:access_message_history])
  end

  test "writes are idempotent and invalid coordinates return controlled errors", %{a: a} do
    for scope <- [:all_people, {:team, a.id}] do
      assert {:ok, grant} = PeoplePermissions.grant(scope, :access_profile)
      assert {:ok, same} = PeoplePermissions.grant(scope, "access_profile")
      assert same.id == grant.id
      assert {:ok, _} = PeoplePermissions.revoke(scope, :access_profile)
      assert {:ok, _} = PeoplePermissions.revoke(scope, :access_profile)
    end

    for scope <- [nil, :person, {:team, nil}, {:team, -1}, {:team, "1"}] do
      assert {:error, :invalid_scope} = PeoplePermissions.grant(scope, :access_profile)
      assert {:error, :invalid_scope} = PeoplePermissions.revoke(scope, :access_profile)
    end

    for permission <- [nil, :unknown, "unknown", %{}] do
      assert {:error, :invalid_permission} = PeoplePermissions.grant(:all_people, permission)
      assert {:error, :invalid_permission} = PeoplePermissions.revoke(:all_people, permission)
    end

    assert {:ok, _} = People.delete_team(a)
    assert {:error, changeset} = PeoplePermissions.grant({:team, a.id}, :access_profile)
    assert errors_on(changeset).scope_id == ["does not exist"]
    assert PeoplePermissions.list_grants() == []
  end

  test "matrix lists stable metadata and explicit cells including empty teams", %{a: a, b: b} do
    Repo.delete_all(from t in Team, where: t.id not in ^[a.id, b.id])
    assert {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    matrix = PeoplePermissions.permissions_matrix()
    assert Enum.map(matrix.scopes, & &1.scope) == [:all_people, {:team, a.id}, {:team, b.id}]

    assert Enum.map(matrix.rows, &{&1.permission, &1.label}) == [
             {:access_profile, "Access profile"},
             {:access_message_history, "Access message history"},
             {:share_conversations, "Share conversations"}
           ]

    assert hd(matrix.rows).grants == MapSet.new([:all_people])
    assert List.last(matrix.rows).grants == MapSet.new()
    Repo.delete_all(Team)

    assert PeoplePermissions.permissions_matrix().scopes == [
             %{scope: :all_people, label: "All People"}
           ]
  end

  property "union is additive, order independent and deduplicated",
           %{person: p, a: a, b: b} do
    check all(
            left <-
              list_of(member_of([:access_profile, :access_message_history, :share_conversations]),
                max_length: 6
              ),
            right <-
              list_of(member_of([:access_profile, :access_message_history, :share_conversations]),
                max_length: 6
              ),
            max_runs: 25
          ) do
      Repo.delete_all(PeoplePermissionGrant)
      for permission <- left, do: PeoplePermissions.grant({:team, a.id}, permission)
      for permission <- right, do: PeoplePermissions.grant({:team, b.id}, permission)
      single = PeoplePermissions.effective_permissions(%{p | team_ids: [a.id]})
      both = %{p | team_ids: [a.id, b.id]}
      union = PeoplePermissions.effective_permissions(both)
      assert MapSet.subset?(single, union)
      assert union == MapSet.new(left ++ right)
      assert union == PeoplePermissions.effective_permissions(%{p | team_ids: [b.id, a.id, b.id]})
    end
  end

  test "each single atom and exact string checks only its own raw grant", %{person: p} do
    for %{permission: permission} <- PeoplePermissionGrant.permissions() do
      Repo.delete_all(PeoplePermissionGrant)
      refute PeoplePermissions.allowed?(p, permission)
      refute PeoplePermissions.allowed?(p, Atom.to_string(permission))
      assert {:ok, _} = PeoplePermissions.grant(:all_people, permission)
      assert PeoplePermissions.allowed?(p, permission)
      assert PeoplePermissions.allowed?(p, Atom.to_string(permission))
      assert PeoplePermissions.allowed?(p, [permission, Atom.to_string(permission)])
      assert PeoplePermissions.effective_permissions(p) == MapSet.new([permission])
    end
  end

  test "empty, unknown and malformed requirements deny even with every grant", %{person: p} do
    for %{permission: permission} <- PeoplePermissionGrant.permissions(),
        do: PeoplePermissions.grant(:all_people, permission)

    for invalid <- [
          [],
          nil,
          false,
          :unknown,
          "unknown",
          "Access_profile",
          "access_profile ",
          1,
          %{},
          {:access_profile},
          [:access_profile, :unknown],
          ["access_profile", "unknown"],
          [:access_profile, nil],
          [[:access_profile]],
          [:access_profile, []],
          [:access_profile | nil],
          [:access_profile | :access_message_history]
        ] do
      refute PeoplePermissions.allowed?(p, invalid)
    end
  end

  property "ALL requirements ignore duplicates, order and atom/string representation", %{
    person: p
  } do
    permissions = [:access_profile, :access_message_history, :share_conversations]

    check all(
            grants <- list_of(member_of(permissions), max_length: 6),
            required <- list_of(member_of(permissions), min_length: 1, max_length: 6),
            max_runs: 25
          ) do
      Repo.delete_all(PeoplePermissionGrant)
      for permission <- grants, do: PeoplePermissions.grant(:all_people, permission)
      expected = Enum.all?(required, &(&1 in grants))
      assert PeoplePermissions.allowed?(p, required) == expected
      assert PeoplePermissions.allowed?(p, Enum.reverse(required) ++ required) == expected
      assert PeoplePermissions.allowed?(p, Enum.map(required, &Atom.to_string/1)) == expected
      refute PeoplePermissions.allowed?(nil, required)
      refute PeoplePermissions.allowed?(p, required ++ [false])
    end
  end

  test "valid requirements resolve grants once without querying Person", %{person: p} do
    assert {:ok, _} = PeoplePermissions.grant(:all_people, :share_conversations)
    handler = {__MODULE__, self()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:zaq, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and metadata[:source] in ["people_permission_grants", "people"] and
               String.starts_with?(metadata.query, "SELECT") do
            send(owner, {:permission_query, metadata.source})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {requirements, expected} <- [
          {:share_conversations, true},
          {"share_conversations", true},
          {[:share_conversations], true},
          {[:share_conversations, "share_conversations"], true},
          {[:share_conversations, :access_profile, :access_message_history], false},
          {:access_profile, false}
        ] do
      assert PeoplePermissions.allowed?(p, requirements) == expected
      assert_received {:permission_query, "people_permission_grants"}
      refute_received {:permission_query, _}
    end

    for requirements <- [[], [:share_conversations, :unknown], [:share_conversations | nil]] do
      refute PeoplePermissions.allowed?(p, requirements)
      refute_received {:permission_query, _}
    end

    refute PeoplePermissions.allowed?(nil, [:share_conversations])
    refute_received {:permission_query, _}
  end

  test "database checks reject bypassed validation and partial indexes enforce null uniqueness",
       %{a: a, b: b} do
    for {scope, id, permission, code} <- [
          {nil, nil, "access_profile", :not_null_violation},
          {"all_people", nil, nil, :not_null_violation},
          {"person", nil, "access_profile", :check_violation},
          {"all_people", a.id, "access_profile", :check_violation},
          {"team", nil, "access_profile", :check_violation},
          {"all_people", nil, "unknown", :check_violation},
          {"team", 9_999_999, "access_profile", :foreign_key_violation}
        ] do
      assert_sql_error(scope, id, permission, code)
    end

    assert {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    assert_sql_error("all_people", nil, "access_profile", :unique_violation)
    assert {:ok, _} = PeoplePermissions.grant({:team, a.id}, :access_profile)
    assert_sql_error("team", a.id, "access_profile", :unique_violation)
    assert {:ok, _} = PeoplePermissions.grant({:team, b.id}, :access_profile)
    Repo.delete!(a)
    assert length(PeoplePermissions.list_grants()) == 2
  end

  defp assert_sql_error(scope, id, permission, code) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Repo.query(
               "INSERT INTO people_permission_grants (scope_type, scope_id, permission, inserted_at, updated_at) VALUES ($1,$2,$3,now(),now())",
               [scope, id, permission],
               mode: :savepoint
             )
  end

  test "schema validates scope shape and maps database field constraints", %{a: a} do
    for {attrs, field} <- [
          {%{}, :scope_type},
          {%{scope_type: "unknown", permission: "access_profile"}, :scope_type},
          {%{scope_type: "all_people", permission: "unknown"}, :permission},
          {%{scope_type: "team", permission: "access_profile"}, :scope_id},
          {%{scope_type: "all_people", scope_id: a.id, permission: "access_profile"}, :scope_id}
        ] do
      changeset = PeoplePermissionGrant.changeset(%PeoplePermissionGrant{}, attrs)
      assert Map.has_key?(errors_on(changeset), field)
    end

    for attrs <- [
          %{scope_type: "all_people", permission: "access_profile"},
          %{scope_type: "team", scope_id: a.id, permission: "access_profile"}
        ] do
      changeset = PeoplePermissionGrant.changeset(%PeoplePermissionGrant{}, attrs)
      assert {:ok, _} = Repo.insert(changeset)
      assert {:error, duplicate} = Repo.insert(changeset, mode: :savepoint)
      assert duplicate.errors != []
    end

    # Keep constraint metadata but bypass application validations to prove mapping.
    valid =
      PeoplePermissionGrant.changeset(%PeoplePermissionGrant{}, %{
        scope_type: "team",
        scope_id: a.id,
        permission: "share_conversations"
      })

    for {field, value} <- [scope_id: nil, permission: "invalid"] do
      changeset = Ecto.Changeset.put_change(valid, field, value)
      assert {:error, rejected} = Repo.insert(changeset, mode: :savepoint)
      assert Map.has_key?(errors_on(rejected), field)
    end
  end
end
