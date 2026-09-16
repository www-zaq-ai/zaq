defmodule Zaq.Accounts.PersonAuthenticationSchemaTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, PersonLoginChallenge, PersonSession}

  setup do
    {:ok, person} = People.create_person(%{full_name: "Authentication schema"})
    %{person: person, expires: DateTime.add(DateTime.utc_now(:second), 300)}
  end

  test "one unfinished challenge per person, including expired challenges", context do
    attrs = %{
      person_id: context.person.id,
      token_digest: :crypto.strong_rand_bytes(32),
      expires_at: context.expires
    }

    assert {:ok, first} =
             PersonLoginChallenge.changeset(
               %PersonLoginChallenge{},
               Map.merge(attrs, %{
                 inserted_at: DateTime.add(context.expires, -900),
                 expires_at: DateTime.add(context.expires, -600)
               })
             )
             |> Repo.insert()

    assert {:error, duplicate} =
             PersonLoginChallenge.changeset(%PersonLoginChallenge{}, attrs)
             |> Repo.insert(mode: :savepoint)

    assert errors_on(duplicate).person_id != []

    assert {:ok, _} =
             first
             |> PersonLoginChallenge.changeset(%{invalidated_at: DateTime.utc_now(:second)})
             |> Repo.update()

    assert {:ok, _} =
             PersonLoginChallenge.changeset(%PersonLoginChallenge{}, attrs) |> Repo.insert()
  end

  test "required digests, attempt and lifecycle constraints", context do
    attrs = %{
      person_id: context.person.id,
      token_digest: :crypto.strong_rand_bytes(32),
      expires_at: context.expires
    }

    for invalid <- [
          %{attempt_count: -1},
          %{token_digest: <<1>>},
          %{consumed_at: DateTime.utc_now(:second), invalidated_at: DateTime.utc_now(:second)}
        ] do
      assert {:error, _} =
               PersonLoginChallenge.changeset(%PersonLoginChallenge{}, Map.merge(attrs, invalid))
               |> Repo.insert(mode: :savepoint)
    end

    assert {:error, _} = PersonSession.changeset(%PersonSession{}, %{}) |> Repo.insert()

    assert {:error, _} =
             PersonSession.changeset(%PersonSession{}, Map.put(attrs, :token_digest, <<1>>))
             |> Repo.insert()

    assert {:error, _} =
             PersonLoginChallenge.changeset(%PersonLoginChallenge{}, %{}) |> Repo.insert()
  end

  test "database itself rejects invalid attempts, lifecycle and digest shape", %{person: person} do
    sql = """
    INSERT INTO person_login_challenges
      (id, person_id, token_digest, expires_at, attempt_count, consumed_at, invalidated_at, inserted_at, updated_at)
    VALUES (gen_random_uuid(), $1, $2, now() + interval '5 minutes', $3, $4, $5, now(), now())
    """

    now = DateTime.utc_now(:second) |> DateTime.to_naive()

    for {digest, attempts, consumed, invalidated} <- [
          {:crypto.strong_rand_bytes(32), -1, nil, nil},
          {<<1>>, 0, nil, nil},
          {:crypto.strong_rand_bytes(32), 0, now, now}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(sql, [person.id, digest, attempts, consumed, invalidated],
                 mode: :savepoint
               )
    end
  end

  test "session digests are unique and authentication rows cascade with the person", context do
    attrs = %{
      person_id: context.person.id,
      token_digest: :crypto.strong_rand_bytes(32),
      expires_at: context.expires
    }

    assert {:ok, session} = PersonSession.changeset(%PersonSession{}, attrs) |> Repo.insert()

    assert {:error, duplicate} =
             PersonSession.changeset(%PersonSession{}, attrs) |> Repo.insert(mode: :savepoint)

    assert errors_on(duplicate).token_digest != []

    assert {:ok, challenge} =
             PersonLoginChallenge.changeset(%PersonLoginChallenge{}, attrs) |> Repo.insert()

    assert {:ok, _} = People.delete_person(context.person)
    refute Repo.get(PersonSession, session.id)
    refute Repo.get(PersonLoginChallenge, challenge.id)

    assert {:error, _} =
             PersonSession.changeset(%PersonSession{}, attrs) |> Repo.insert(mode: :savepoint)

    assert {:error, _} =
             PersonLoginChallenge.changeset(%PersonLoginChallenge{}, attrs)
             |> Repo.insert(mode: :savepoint)
  end
end
