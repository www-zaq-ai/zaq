defmodule Zaq.Engine.PeopleCredentials.AuthorizationTest do
  use Zaq.DataCase, async: true
  alias Zaq.Accounts.{PeoplePermissions, Person, PersonSession}
  alias Zaq.Engine.PeopleCredentials.Authorization

  setup do
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Bound owner"}))

    session =
      Repo.insert!(
        PersonSession.changeset(%PersonSession{}, %{
          person_id: person.id,
          token_digest: :crypto.strong_rand_bytes(32),
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
        })
      )

    %{person: person, session: session}
  end

  defp revalidate(person, session) do
    Repo.transaction(fn ->
      case Authorization.revalidate_session(person.id, session.id, []) do
        {:ok, auth} -> auth
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  test "revalidation requires the completion transaction and current management permission",
       ctx do
    assert {:error, :transaction_required} =
             Authorization.revalidate_session(ctx.person.id, ctx.session.id, [])

    assert {:ok, %{person: %{id: id}}} = revalidate(ctx.person, ctx.session)
    assert id == ctx.person.id
    {:ok, _} = PeoplePermissions.revoke(:everyone, :manage_credentials)
    assert {:error, :forbidden} = revalidate(ctx.person, ctx.session)
  end

  test "Accounts rejects inactive literal identity, revoked session and a different owner", ctx do
    assert {:error, :invalid_session} = revalidate(%{id: ctx.person.id + 9999}, ctx.session)
    Repo.update!(Ecto.Changeset.change(ctx.person, status: "inactive"))
    assert {:error, :invalid_session} = revalidate(ctx.person, ctx.session)
    Repo.update!(Ecto.Changeset.change(ctx.person, status: "active"))
    Repo.update!(Ecto.Changeset.change(ctx.session, revoked_at: DateTime.utc_now(:second)))
    assert {:error, :invalid_session} = revalidate(ctx.person, ctx.session)
  end
end
