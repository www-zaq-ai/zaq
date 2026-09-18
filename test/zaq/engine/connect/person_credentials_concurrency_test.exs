defmodule Zaq.Engine.Connect.PersonCredentialsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, PersonCredentials}
  alias Zaq.Repo

  for action <- [
        :put_own_authentication,
        :revoke_own_grant,
        :remove_own_grant
      ] do
    test "#{action} rechecks identity at the mutation boundary after the initial read" do
      {person, credential} =
        Sandbox.unboxed_run(Repo, fn ->
          person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Race owner"}))

          {:ok, credential} =
            Connect.create_credential(%{
              name: "person-race-#{Ecto.UUID.generate()}",
              provider: "example",
              auth_kind: "api_key",
              secret_binding: :grant,
              personal_credential_policy: :required
            })

          {:ok, _} =
            Connect.replace_credential_grant(credential, {:person, person.id}, %{
              api_key: "original"
            })

          {person, credential}
        end)

      handler_id = {__MODULE__, make_ref()}
      parent = self()

      on_exit(fn ->
        :telemetry.detach(handler_id)

        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from c in Credential, where: c.id == ^credential.id)
          Repo.delete_all(from p in Person, where: p.id == ^person.id)

          Repo.delete_all(
            from j in Oban.Job,
              where:
                j.queue == "connect_credential_notifications" and
                  fragment("?->>'credential_id'", j.args) == ^to_string(credential.id)
          )
        end)
      end)

      task =
        Task.async(fn ->
          receive do
            :start ->
              Sandbox.unboxed_run(Repo, fn ->
                args = [person, credential.id]

                args =
                  if unquote(action) == :put_own_authentication,
                    do: args ++ [%{api_key: "replacement"}],
                    else: args

                apply(PersonCredentials, unquote(action), args)
              end)
          end
        end)

      :ok =
        :telemetry.attach(
          handler_id,
          [:zaq, :repo, :query],
          &__MODULE__.pause_initial_identity_read/4,
          %{caller: task.pid, parent: parent}
        )

      send(task.pid, :start)
      assert_receive {:identity_read, caller}, 5_000

      Sandbox.unboxed_run(Repo, fn ->
        Repo.update!(Person.update_changeset(person, %{status: "inactive"}))
      end)

      send(caller, :continue)
      assert {:error, :unauthorized} = Task.await(task, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        grant = Repo.get_by!(Grant, credential_id: credential.id, owner_id: person.id)
        assert grant.status == "active"
        assert grant.api_key == "original"
      end)
    end
  end

  # Repo telemetry is an existing observation boundary, not an injected internal mock.
  # Pause once after the actual initial identity SELECT; the independent connection
  # changes identity before the mutation's credential lock and second identity SELECT.
  def pause_initial_identity_read(_event, _measurements, metadata, config) do
    if self() == config.caller and metadata.source == "people" and
         not Process.get({__MODULE__, :paused}, false) do
      Process.put({__MODULE__, :paused}, true)
      send(config.parent, {:identity_read, self()})

      receive do
        :continue -> :ok
      after
        5_000 -> raise "identity read barrier timeout"
      end
    end
  end
end
