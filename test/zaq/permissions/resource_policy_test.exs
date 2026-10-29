defmodule Zaq.Permissions.ResourcePolicyTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Permissions.ResourcePolicy

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{resource_type: "storage_entry", resource_id: "00000000-0000-4000-8000-000000000042"},
      extra
    )
  end

  test "unset fields inherit while explicit zero remains stored" do
    assert {:ok, policy} = %ResourcePolicy{} |> ResourcePolicy.changeset(attrs()) |> Repo.insert()
    assert is_nil(policy.classification_level)
    assert is_nil(policy.clearance_level)
    assert policy.lock_version == 1

    assert {:ok, updated} =
             policy
             |> ResourcePolicy.changeset(%{classification_level: 0, clearance_level: 7})
             |> Repo.update()

    assert updated.classification_level == 0
    assert updated.clearance_level == 7
    assert updated.lock_version == 2

    assert {:ok, reset} =
             updated
             |> ResourcePolicy.changeset(%{classification_level: nil})
             |> Repo.update()

    assert is_nil(reset.classification_level)
    assert reset.clearance_level == 7
  end

  test "levels reject floats, booleans, blanks, negative and overflowing values" do
    for field <- [:classification_level, :clearance_level],
        value <- [-1, 1.0, true, false, "", " ", "1.0", " 2", "2 ", "2x", %{}, [], 2_147_483_648] do
      changeset =
        ResourcePolicy.changeset(%ResourcePolicy{}, attrs(%{field => value}))

      refute changeset.valid?, "accepted #{inspect(value)}"
      assert errors_on(changeset)[field]
    end

    assert ResourcePolicy.changeset(%ResourcePolicy{}, attrs(%{clearance_level: "2147483647"})).valid?
  end

  test "integer strings use Ecto casting without treating blanks as inheritance" do
    for {input, expected} <- [
          {"+2", 2},
          {"002", 2},
          {"-0", 0},
          {String.duplicate("0", 30) <> "2", 2}
        ] do
      changeset = ResourcePolicy.changeset(%ResourcePolicy{}, attrs(%{clearance_level: input}))
      assert changeset.valid?
      assert get_field(changeset, :clearance_level) == expected
    end

    # Ecto bounds integer-string casting to fewer than 32 bytes.
    refute ResourcePolicy.changeset(
             %ResourcePolicy{},
             attrs(%{clearance_level: String.duplicate("0", 31) <> "2"})
           ).valid?

    policy = %ResourcePolicy{classification_level: 2, clearance_level: 4}
    refute ResourcePolicy.changeset(policy, %{classification_level: ""}).valid?
    assert get_field(ResourcePolicy.changeset(policy, %{}), :classification_level) == 2
  end

  test "coordinates are registered, required and immutable after insertion" do
    for extra <- [%{resource_type: "arbitrary_table"}, %{resource_id: ""}, %{resource_id: "0"}] do
      refute ResourcePolicy.changeset(%ResourcePolicy{}, attrs(extra)).valid?
    end

    assert {:ok, policy} = %ResourcePolicy{} |> ResourcePolicy.changeset(attrs()) |> Repo.insert()

    refute ResourcePolicy.changeset(policy, %{
             resource_id: "00000000-0000-4000-8000-000000000043"
           }).valid?

    refute ResourcePolicy.changeset(policy, %{resource_type: "person"}).valid?
    refute ResourcePolicy.changeset(%ResourcePolicy{}, []).valid?
  end

  test "one policy per target is enforced by the database" do
    assert {:ok, _} = %ResourcePolicy{} |> ResourcePolicy.changeset(attrs()) |> Repo.insert()

    assert {:error, changeset} =
             %ResourcePolicy{}
             |> ResourcePolicy.changeset(attrs(%{clearance_level: 3}))
             |> Repo.insert(mode: :savepoint)

    assert errors_on(changeset).resource_id == ["has already been taken"]
  end

  test "database constraints reject invalid levels without changeset validation" do
    changeset =
      %ResourcePolicy{}
      |> change(attrs(%{classification_level: -1}))
      |> check_constraint(:classification_level,
        name: :resource_policies_classification_nonnegative
      )

    assert {:error, invalid} = Repo.insert(changeset, mode: :savepoint)
    assert errors_on(invalid).classification_level == ["is invalid"]
  end

  test "stale edits cannot overwrite newer independent values" do
    {:ok, policy} = %ResourcePolicy{} |> ResourcePolicy.changeset(attrs()) |> Repo.insert()
    {:ok, _} = policy |> ResourcePolicy.changeset(%{clearance_level: 4}) |> Repo.update()

    assert {:error, stale} =
             policy
             |> ResourcePolicy.changeset(%{classification_level: 2})
             |> Repo.update(stale_error_field: :lock_version)

    assert errors_on(stale).lock_version == ["is stale"]
    assert Repo.get!(ResourcePolicy, policy.id).clearance_level == 4
  end

  property "both valid levels survive validation independently, including zero" do
    check all(classification <- integer(0..2_147_483_647), clearance <- integer(0..2_147_483_647)) do
      for {classification_input, clearance_input} <- [
            {classification, clearance},
            {Integer.to_string(classification), Integer.to_string(clearance)}
          ] do
        changeset =
          ResourcePolicy.changeset(
            %ResourcePolicy{},
            attrs(%{classification_level: classification_input, clearance_level: clearance_input})
          )

        assert changeset.valid?
        assert get_field(changeset, :classification_level) == classification
        assert get_field(changeset, :clearance_level) == clearance
      end
    end
  end
end
