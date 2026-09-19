defmodule Zaq.Engine.Connect.OAuthAttemptsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, OAuthAttempts, OAuthState}
  alias Zaq.Engine.Connect.PersonLifecycle
  alias Zaq.Engine.Connect.SecretReconciliationWorker
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP, PersonOAuth}
  @opts [config: ConnectOAuthAttemptConfig]
  setup {Req.Test, :verify_on_exit!}

  for mutation <- [
        :none,
        :person,
        :config,
        :delete_person,
        :merge_loser,
        :merge_survivor,
        :reconcile_claimed
      ] do
    test "claim commits before HTTP, concurrent replay loses; #{mutation} rechecked before save" do
      Code.ensure_loaded!(ConnectOAuthAttemptConfig)

      {person, other, credential, original, state} =
        Sandbox.unboxed_run(Repo, fn ->
          person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "OAuth race"}))
          other = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Other identity"}))

          {:ok, dto} =
            Connect.save_credential_configuration(nil, %{
              name: "race-#{Ecto.UUID.generate()}",
              provider: "example",
              auth_kind: "oauth2",
              secret_binding: :grant,
              personal_credential_policy: :required,
              client_id: "client",
              metadata: %{
                "authorize_url" => "https://provider.example/authorize",
                "token_url" => "https://provider.example/token"
              }
            })

          credential = Repo.get!(Credential, dto.credential_id)
          {:ok, _} = PersonOAuth.associate(credential.id)

          {:ok, original} =
            Connect.replace_credential_grant(credential, {:person, person.id}, %{
              access_token: "previous"
            })

          {:ok, %{authorize_url: url}} =
            PersonOAuth.start(person, credential.id, @opts)

          {person, other, credential, original, URI.decode_query(URI.parse(url).query)["state"]}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
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
        send(parent, {:exchange_entered, self()})

        receive do
          :continue -> Req.Test.json(conn, %{"access_token" => "replacement"})
        after
          5_000 -> flunk("exchange barrier timeout")
        end
      end)

      callback = fn ->
        OAuthAttempts.finalize_callback("example", %{"state" => state, "code" => "code"}, @opts)
      end

      task = Task.async(fn -> Sandbox.unboxed_run(Repo, callback) end)
      assert_receive {:exchange_entered, exchanger}, 5_000
      assert {:error, :invalid_attempt} = Sandbox.unboxed_run(Repo, callback)
      assert {:ok, %{"attempt_id" => attempt_id}} = OAuthState.verify(state)

      Sandbox.unboxed_run(Repo, fn ->
        assert %{rows: [[claimed, nil, nil]]} =
                 Repo.query!(
                   "SELECT claimed_at, pkce_verifier, candidate_config FROM connect_oauth_attempts WHERE id = $1",
                   [attempt_id]
                 )

        refute is_nil(claimed)

        case unquote(mutation) do
          :none ->
            :ok

          :person ->
            Repo.update!(Person.update_changeset(person, %{status: "inactive"}))

          :delete_person ->
            assert {:ok, _} = People.delete_person(person)

          :merge_loser ->
            assert {:ok, _} = People.merge_persons(other, person)

          :merge_survivor ->
            assert {:ok, _} = People.merge_persons(person, other)

          :reconcile_claimed ->
            assert :ok =
                     SecretReconciliationWorker.perform(%Oban.Job{args: %{}})

            assert {:ok, %{attempts_deleted: 0}} = PersonLifecycle.reconcile()

          :config ->
            assert {:ok, _} =
                     Connect.save_credential_configuration(credential, %{
                       name: "changed-#{Ecto.UUID.generate()}"
                     })
        end
      end)

      send(exchanger, :continue)
      result = Task.await(task, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        if unquote(mutation) in [:none, :reconcile_claimed] do
          assert {:ok, %{status: "active"}} = result
          assert Repo.get!(Grant, original.grant_id).access_token == "replacement"
        else
          assert {:error, :invalid_attempt} = result

          if unquote(mutation) == :delete_person,
            do: refute(Repo.get(Grant, original.grant_id)),
            else: assert(Repo.get!(Grant, original.grant_id).access_token == "previous")
        end

        assert Repo.aggregate(from(g in Grant, where: g.credential_id == ^credential.id), :count) ==
                 if(unquote(mutation) == :delete_person, do: 0, else: 1)
      end)
    end
  end
end
