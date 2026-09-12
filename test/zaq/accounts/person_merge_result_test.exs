defmodule Zaq.Accounts.PersonMergeResultTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, Person}

  test "protected result persistence validates profile and identity together without implicit channel edits" do
    {:ok, person} = People.create_person(%{full_name: "Original"})
    history = [%{"id" => 99, "label" => "Previous", "merged_at" => "2026-01-01T00:00:00Z"}]

    attrs = %{
      full_name: "Final",
      email: " FINAL@example.com ",
      phone: "123",
      merged_person_ids: [99],
      merge_history: history
    }

    assert {:ok, result} = People.apply_merge_result(person, attrs)
    assert result.full_name == "Final"
    assert result.email == "final@example.com"
    assert result.merged_person_ids == [99]
    assert result.merge_history == history
    refute result.incomplete
    assert People.list_person_channels(person.id) == []

    assert {:error, changeset} =
             People.apply_merge_result(result, %{status: "invalid", merged_person_ids: [100]})

    assert errors_on(changeset).status == ["is invalid"]
    assert People.get_person!(person.id) == result

    assert {:error, changeset} =
             People.apply_merge_result(result, %{merged_person_ids: ["invalid"]})

    assert errors_on(changeset).merged_person_ids == ["is invalid"]
  end

  test "ordinary changesets ignore protected results on both create and update" do
    attrs = %{full_name: "Ordinary", merged_person_ids: [99], merge_history: [%{"id" => 99}]}

    for changeset <- [
          Person.changeset(%Person{}, attrs),
          Person.update_changeset(%Person{}, attrs)
        ] do
      refute Map.has_key?(changeset.changes, :merged_person_ids)
      refute Map.has_key?(changeset.changes, :merge_history)
    end
  end
end
