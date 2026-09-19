defmodule Zaq.Engine.Connect.RefreshConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, PeoplePermissions, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, GrantRefreshWorker}
  alias Zaq.Engine.Connect.OAuthAttempts
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP, PersonOAuth}

  @now ~U[2026-09-19 09:00:00Z]
  @opts [config: ConnectOAuthAttemptConfig, now: @now]
  setup {Req.Test, :verify_on_exit!}

  for mutation <- [
        :none,
        :revoke,
        :replace,
        :reauthorize,
        :delete,
        :credential_delete,
        :config,
        :policy,
        :client_config,
        :ciphertext,
        :person,
        :person_delete,
        :lifecycle_delete,
        :lifecycle_merge
      ] do
    test "independent scheduled/on-demand single flight; #{mutation} wins during HTTP" do
      Code.ensure_loaded!(ConnectOAuthAttemptConfig)

      {person, other, credential, grant} =
        Sandbox.unboxed_run(Repo, fn ->
          person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Refresh race"}))
          other = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Other identity"}))

          {:ok, dto} =
            Connect.save_credential_configuration(nil, %{
              name: "refresh-#{Ecto.UUID.generate()}",
              provider: "example",
              auth_kind: "oauth2",
              secret_binding: :grant,
              personal_credential_policy: :required,
              client_id: "client",
              metadata: %{
                "token_url" => "https://provider.example/token",
                "authorize_url" => "https://provider.example/authorize"
              }
            })

          credential = Repo.get!(Credential, dto.credential_id)

          {:ok, dto} =
            Connect.replace_credential_grant(credential, {:person, person.id}, %{
              access_token: "old-access",
              refresh_token: "old-refresh"
            })

          grant = Repo.get!(Grant, dto.grant_id)
          grant = Repo.update!(Ecto.Changeset.change(grant, expires_at: ~U[2020-01-01 00:00:00Z]))
          {person, other, credential, grant}
        end)

      permissions_to_restore =
        if unquote(mutation) == :reauthorize do
          Sandbox.unboxed_run(Repo, fn ->
            everyone_id = People.everyone_team().id

            for permission <- [:access_profile, :manage_credentials],
                not Enum.any?(PeoplePermissions.list_grants(), fn grant ->
                  grant.scope_id == everyone_id and grant.permission == to_string(permission)
                end),
                do: permission
          end)
        else
          []
        end

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          for permission <- permissions_to_restore do
            PeoplePermissions.revoke(:everyone, permission)
          end

          Repo.delete_all(
            from ai in AIProviderCredential,
              where: ai.connect_credential_id == ^credential.id
          )

          Repo.delete_all(from c in Credential, where: c.id == ^credential.id)
          Repo.delete_all(from p in Person, where: p.id in ^[person.id, other.id])

          Repo.delete_all(
            from j in Oban.Job,
              where:
                j.queue == "connect_credential_notifications" and
                  fragment("?->>'credential_id'", j.args) == ^to_string(credential.id)
          )
        end)
      end)

      parent = self()

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        refute Repo.in_transaction?()
        send(parent, {:refresh_entered, self()})

        receive do
          :continue ->
            Req.Test.json(conn, %{"access_token" => "new-access", "expires_in" => 3600})
        after
          5_000 -> flunk("refresh barrier timeout")
        end
      end)

      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn -> Connect.prepare_grant_for_use(grant, @opts) end)
        end)

      assert_receive {:refresh_entered, refresher}, 5_000

      assert {:snooze, 120} =
               Sandbox.unboxed_run(Repo, fn ->
                 GrantRefreshWorker.perform(%Oban.Job{args: %{"grant_id" => grant.id}}, @opts)
               end)

      Sandbox.unboxed_run(Repo, fn ->
        case unquote(mutation) do
          :none ->
            :ok

          :revoke ->
            assert {:ok, _} = Connect.revoke_credential_grant(credential, {:person, person.id})

          :replace ->
            assert {:ok, _} =
                     Connect.replace_credential_grant(credential, {:person, person.id}, %{
                       access_token: "replacement"
                     })

          :delete ->
            assert {:ok, _} = Connect.remove_credential_grant(credential, {:person, person.id})

          :reauthorize ->
            {:ok, _} = PersonOAuth.associate(credential.id)

            assert {:ok, %{authorize_url: url}} =
                     PersonOAuth.start(person, credential.id, @opts)

            state = URI.decode_query(URI.parse(url).query)["state"]

            Req.Test.expect(
              ConnectOAuthAttemptHTTP,
              &Req.Test.json(&1, %{"access_token" => "reauthorized"})
            )

            assert {:ok, _} =
                     OAuthAttempts.finalize_callback(
                       "example",
                       %{"state" => state, "code" => "reauth-code"},
                       @opts
                     )

            for permission <- permissions_to_restore do
              assert {:ok, 1} = PeoplePermissions.revoke(:everyone, permission)
            end

          :credential_delete ->
            assert {:ok, _} = Connect.delete_credential(credential)

          :config ->
            assert {:ok, _} =
                     Connect.save_credential_configuration(credential, %{
                       name: "changed-#{Ecto.UUID.generate()}"
                     })

          :person ->
            Repo.update!(Person.update_changeset(person, %{status: "inactive"}))

          :policy ->
            assert {:ok, _} =
                     Connect.update_credential(credential, %{
                       personal_credential_policy: :disabled
                     })

          :client_config ->
            assert {:ok, _} =
                     Connect.update_credential(credential, %{client_id: "different-client"})

          :ciphertext ->
            Repo.query!(
              "UPDATE connect_grants SET access_token = 'enc:v1:broken' WHERE id = $1",
              [grant.id]
            )

          :person_delete ->
            Repo.delete!(person)

          :lifecycle_delete ->
            assert {:ok, _} = People.delete_person(person)

          :lifecycle_merge ->
            assert {:ok, _} = People.merge_persons(other, person)
        end
      end)

      send(refresher, :continue)
      result = Task.await(task, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        if unquote(mutation) == :none do
          assert {:ok, %{access_token: "new-access", refresh_token: "old-refresh"}} = result
          assert Repo.get!(Grant, grant.id).access_token == "new-access"

          assert Repo.aggregate(
                   from(j in Oban.Job,
                     where:
                       fragment("?->>'grant_id'", j.args) == ^to_string(grant.id) and
                         fragment("?->>'kind'", j.args) == "grant_tokens_updated"
                   ),
                   :count
                 ) == 1
        else
          assert {:error, reason} = result
          assert reason in [:stale_grant, :not_found, :person_unavailable, :revoked]
          refute match?(%{access_token: "new-access"}, Repo.get(Grant, grant.id))
        end
      end)
    end
  end
end
