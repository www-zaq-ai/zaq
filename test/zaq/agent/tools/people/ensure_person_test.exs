defmodule Zaq.Agent.Tools.People.EnsurePersonTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.People.EnsurePerson
  alias Zaq.Repo

  defp draft(overrides \\ %{}) do
    Map.merge(
      %{
        to_address: "alice@example.com",
        to_name: "Alice Smith",
        subject: "Re: Hello",
        draft: "Hi Alice!"
      },
      overrides
    )
  end

  describe "run/2 — existing person found" do
    test "enriches draft with existing person_id and does not update name" do
      {:ok, person} =
        People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})

      params = %{drafts: [draft()]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})
      assert enriched.person_id == person.id
    end

    test "does not overwrite name when existing name differs from email address" do
      {:ok, person} =
        People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})

      params = %{drafts: [draft(%{to_name: "Alice S."})]}
      assert {:ok, %{drafts: [_enriched]}, _logs} = EnsurePerson.run(params, %{})

      # Name should not be changed — the current name is "Alice Smith", not the email address
      updated = Repo.get!(Person, person.id)
      assert updated.full_name == "Alice Smith"
    end

    test "updates stale name when current name equals email address" do
      # Person was created with email as name (stale fallback)
      {:ok, person} =
        People.create_person(%{full_name: "alice@example.com", email: "alice@example.com"})

      params = %{drafts: [draft(%{to_name: "Alice Smith"})]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})
      assert enriched.person_id == person.id

      updated = Repo.get!(Person, person.id)
      assert updated.full_name == "Alice Smith"
    end

    test "does not update name when to_name is nil and current name equals email" do
      {:ok, person} =
        People.create_person(%{full_name: "alice@example.com", email: "alice@example.com"})

      params = %{drafts: [draft(%{to_name: nil})]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})
      assert enriched.person_id == person.id

      updated = Repo.get!(Person, person.id)
      assert updated.full_name == "alice@example.com"
    end

    test "does not update name when to_name is empty string" do
      {:ok, person} =
        People.create_person(%{full_name: "alice@example.com", email: "alice@example.com"})

      params = %{drafts: [draft(%{to_name: ""})]}
      assert {:ok, %{drafts: [_enriched]}, _logs} = EnsurePerson.run(params, %{})

      updated = Repo.get!(Person, person.id)
      assert updated.full_name == "alice@example.com"
    end
  end

  describe "run/2 — new person created" do
    test "creates person and enriches draft with new person_id" do
      refute Repo.get_by(Person, email: "bob@example.com")

      params = %{drafts: [draft(%{to_address: "bob@example.com", to_name: "Bob Jones"})]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})
      assert is_integer(enriched.person_id)

      person = Repo.get!(Person, enriched.person_id)
      assert person.email == "bob@example.com"
      assert person.full_name == "Bob Jones"
    end

    test "uses email address as name when to_name is nil" do
      params = %{drafts: [draft(%{to_address: "noop@example.com", to_name: nil})]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})

      person = Repo.get!(Person, enriched.person_id)
      assert person.full_name == "noop@example.com"
    end

    test "uses email address as name when to_name is empty string" do
      params = %{drafts: [draft(%{to_address: "empty@example.com", to_name: ""})]}
      assert {:ok, %{drafts: [enriched]}, _logs} = EnsurePerson.run(params, %{})

      person = Repo.get!(Person, enriched.person_id)
      assert person.full_name == "empty@example.com"
    end
  end

  describe "run/2 — logs" do
    test "emits an info log with the count of enriched drafts" do
      {:ok, _person} =
        People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})

      assert {:ok, _result, logs: logs} = EnsurePerson.run(%{drafts: [draft()]}, %{})

      assert [
               %{
                 level: "info",
                 message: _msg,
                 metadata: %{count: 1, addresses: ["alice@example.com"]}
               }
             ] = logs
    end

    test "emits an info log with count 0 for empty drafts" do
      assert {:ok, _result, logs: logs} = EnsurePerson.run(%{drafts: []}, %{})
      assert [%{level: "info", metadata: %{count: 0, addresses: []}}] = logs
    end
  end

  describe "run/2 — multiple drafts" do
    test "enriches all drafts independently" do
      {:ok, existing} =
        People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})

      drafts = [
        draft(%{to_address: "alice@example.com", to_name: "Alice Smith"}),
        draft(%{to_address: "carol@example.com", to_name: "Carol"})
      ]

      assert {:ok, %{drafts: [a, c]}, _logs} = EnsurePerson.run(%{drafts: drafts}, %{})
      assert a.person_id == existing.id
      assert is_integer(c.person_id)
      assert c.person_id != existing.id
    end

    test "returns empty drafts list when input is empty" do
      assert {:ok, %{drafts: []}, _logs} = EnsurePerson.run(%{drafts: []}, %{})
    end
  end
end
