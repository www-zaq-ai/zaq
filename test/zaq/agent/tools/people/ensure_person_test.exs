defmodule Zaq.Agent.Tools.People.EnsurePersonTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Agent.Tools.People.EnsurePerson
  alias Zaq.Repo

  @ctx %{}

  describe "run/2 — email platform, existing person" do
    test "returns existing person matched by email" do
      {:ok, person} =
        People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})

      person_id = person.id

      assert {:ok, %{person: %{id: ^person_id}, row: _} = result} =
               EnsurePerson.run(%{platform: "email", email: "alice@example.com"}, @ctx)

      assert {:ok, _json} = Jason.encode(result)
      refute Map.has_key?(result, :person_id)
    end

    test "does not create a duplicate person" do
      {:ok, _} = People.create_person(%{full_name: "Alice Smith", email: "alice@example.com"})
      count_before = Repo.aggregate(Person, :count)

      EnsurePerson.run(%{platform: "email", email: "alice@example.com"}, @ctx)

      assert Repo.aggregate(Person, :count) == count_before
    end
  end

  describe "run/2 — email platform, new person" do
    test "creates person when email is not found" do
      refute Repo.get_by(Person, email: "new@example.com")

      assert {:ok, %{person: %{id: person_id}, row: _} = result} =
               EnsurePerson.run(
                 %{platform: "email", email: "new@example.com", display_name: "New Person"},
                 @ctx
               )

      refute Map.has_key?(result, :person_id)

      person = Repo.get!(Person, person_id)
      assert person.email == "new@example.com"
      assert person.full_name == "New Person"
    end

    test "uses email as full_name when display_name is absent" do
      assert {:ok, %{person: %{id: person_id}}} =
               EnsurePerson.run(%{platform: "email", email: "noname@example.com"}, @ctx)

      person = Repo.get!(Person, person_id)
      assert person.email == "noname@example.com"
    end

    test "uses name field as fallback for display_name" do
      # Simulates runtime: atom keys from static params, string keys from accumulator
      params =
        Map.merge(%{platform: "email", email: "named@example.com"}, %{"name" => "Named Person"})

      assert {:ok, %{person: %{id: person_id}}} =
               EnsurePerson.run(params, @ctx)

      person = Repo.get!(Person, person_id)
      assert person.full_name == "Named Person"
    end

    test "links an email PersonChannel on creation" do
      assert {:ok, %{person: %{id: person_id}}} =
               EnsurePerson.run(%{platform: "email", email: "linked@example.com"}, @ctx)

      channels = Repo.all(from c in PersonChannel, where: c.person_id == ^person_id)

      assert Enum.any?(
               channels,
               &(&1.platform == "email" && &1.channel_identifier == "linked@example.com")
             )
    end
  end

  describe "run/2 — channel_id as primary identifier" do
    test "uses channel_id when provided explicitly" do
      assert {:ok, %{person: %{id: person_id}} = result} =
               EnsurePerson.run(
                 %{
                   platform: "mattermost",
                   channel_id: "user123",
                   display_name: "Bob"
                 },
                 @ctx
               )

      assert is_integer(person_id)
      refute Map.has_key?(result, :person_id)

      channels = Repo.all(from c in PersonChannel, where: c.channel_identifier == "user123")
      assert length(channels) == 1
      assert hd(channels).platform == "mattermost"
    end

    test "defaults channel_id to email when platform is email and channel_id is absent" do
      assert {:ok, %{person: %{id: person_id}}} =
               EnsurePerson.run(%{platform: "email", email: "implicit@example.com"}, @ctx)

      channels = Repo.all(from c in PersonChannel, where: c.person_id == ^person_id)
      assert Enum.any?(channels, &(&1.channel_identifier == "implicit@example.com"))
    end
  end

  describe "run/2 — row passthrough" do
    test "returns all input data as string-keyed row (drops platform)" do
      params =
        Map.merge(
          %{platform: "email", email: "row@example.com", display_name: "Row Test"},
          %{"company" => "Acme", "row_index" => 3}
        )

      assert {:ok, %{row: row}} = EnsurePerson.run(params, @ctx)

      assert Map.get(row, "email") == "row@example.com"
      assert Map.get(row, "company") == "Acme"
      assert Map.get(row, "row_index") == 3
      refute Map.has_key?(row, "platform")
      refute Map.has_key?(row, :platform)
    end

    test "row keys are all strings" do
      assert {:ok, %{row: row}} =
               EnsurePerson.run(%{platform: "email", email: "strkeys@example.com"}, @ctx)

      assert Enum.all?(Map.keys(row), &is_binary/1)
    end
  end
end
