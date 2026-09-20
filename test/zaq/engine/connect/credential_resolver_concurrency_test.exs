defmodule Zaq.Engine.Connect.CredentialResolverConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP}

  @now ~U[2026-09-14 12:00:00Z]
  @opts [config: ConnectOAuthAttemptConfig, now: @now]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)

    {person, c, personal, org} =
      Sandbox.unboxed_run(Repo, fn ->
        person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Resolver race"}))

        {:ok, c} =
          Connect.create_credential(%{
            name: "resolver-race-#{Ecto.UUID.generate()}",
            provider: "example",
            auth_kind: "oauth2",
            client_id: "client",
            secret_binding: :grant,
            personal_credential_policy: :optional,
            metadata: %{"token_url" => "https://provider.example/token"}
          })

        {:ok, personal} =
          Connect.replace_credential_grant(c, {:person, person.id}, %{
            access_token: "personal",
            refresh_token: "personal-refresh"
          })

        {:ok, org} =
          Connect.replace_credential_grant(c, :org, %{
            access_token: "global",
            refresh_token: "global-refresh"
          })

        {person, c, Repo.get!(Grant, personal.grant_id), Repo.get!(Grant, org.grant_id)}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Credential, where: c.id == ^c.id)
        Repo.delete_all(from p in Person, where: p.id == ^person.id)

        Repo.delete_all(
          from j in Oban.Job,
            where:
              j.queue == "connect_credential_notifications" and
                fragment("?->>'credential_id'", j.args) == ^to_string(c.id)
        )
      end)
    end)

    %{person: person, c: c, personal: personal, org: org}
  end

  test "non-OAuth resolution evaluates its clock only after acquiring selection locks" do
    {credential, grant} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, credential} =
          Connect.create_credential(%{
            name: "resolver-lock-clock-#{Ecto.UUID.generate()}",
            provider: "example",
            auth_kind: "api_key",
            secret_binding: :grant,
            personal_credential_policy: :required,
            expires_at: DateTime.add(@now, 10)
          })

        {:ok, grant} = Connect.replace_credential_grant(credential, :org, %{api_key: "global"})
        {credential, Repo.get!(Grant, grant.grant_id)}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Credential, where: c.id == ^credential.id)
      end)
    end)

    parent = self()

    locker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from c in Credential, where: c.id == ^credential.id, lock: "FOR UPDATE")
            send(parent, :credential_locked)

            receive do
              :release_credential -> :ok
            after
              5_000 -> flunk("credential lock release timeout")
            end
          end)
        end)
      end)

    assert_receive :credential_locked, 5_000

    resolver =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Connect.resolve_credential(credential.id, nil,
            config: ConnectOAuthAttemptConfig,
            now: fn ->
              send(parent, :clock_read)
              DateTime.add(@now, 20)
            end
          )
        end)
      end)

    refute_receive :clock_read, 200
    send(locker.pid, :release_credential)
    assert {:ok, :ok} = Task.await(locker, 5_000)
    assert_receive :clock_read, 5_000

    assert Task.await(resolver, 5_000) ==
             {:error,
              %{credential_id: credential.id, reason: :credential_expired, owner_type: "org"}}

    assert grant.credential_id == credential.id
  end

  for expiry <- [:configuration, :grant] do
    test "final OAuth validation reevaluates function clock for #{expiry} expiry", ctx do
      Sandbox.unboxed_run(Repo, fn ->
        Repo.update!(Ecto.Changeset.change(ctx.personal, expires_at: @now))

        if unquote(expiry) == :configuration,
          do: Repo.update!(Ecto.Changeset.change(ctx.c, expires_at: DateTime.add(@now, 10)))
      end)

      clock = start_supervised!({Agent, fn -> @now end})
      opts = Keyword.put(@opts, :now, fn -> Agent.get(clock, & &1) end)
      handler = make_ref()

      :ok =
        :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.advance_after_refresh/4, %{
          caller: self(),
          clock: clock
        })

      on_exit(fn -> :telemetry.detach(handler) end)

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        Agent.update(clock, fn _ -> DateTime.add(@now, 20) end)
        if unquote(expiry) == :grant, do: Process.put(:advance_after_refresh, true)

        expiry =
          if unquote(expiry) == :grant, do: DateTime.add(@now, 30), else: DateTime.add(@now, 3600)

        Req.Test.json(conn, %{
          "access_token" => "late-token",
          "expires_at" => DateTime.to_iso8601(expiry)
        })
      end)

      result =
        Sandbox.unboxed_run(Repo, fn ->
          Connect.resolve_credential(ctx.c, %{person_id: ctx.person.id}, opts)
        end)

      assert {:error, %{credential_id: id, reason: :credential_expired}} = result
      assert id == ctx.c.id
    end
  end

  for {mutation, reason} <- [
        {:none, nil},
        {:replace, :credential_unavailable},
        {:revoke, :credential_revoked},
        {:remove, :credential_unavailable},
        {:config, :credential_unavailable},
        {:person, :person_unavailable},
        {:disabled_person, :person_unavailable},
        {:ciphertext, :credential_unavailable}
      ] do
    @mutation mutation
    @reason reason
    test "committed #{@mutation} wins during selected OAuth refresh", ctx do
      selected =
        Sandbox.unboxed_run(Repo, fn ->
          if @mutation == :disabled_person do
            Repo.update!(Ecto.Changeset.change(ctx.c, personal_credential_policy: :disabled))
            Repo.update!(Ecto.Changeset.change(ctx.org, expires_at: @now))
          else
            Repo.update!(Ecto.Changeset.change(ctx.personal, expires_at: @now))
          end
        end)

      parent = self()

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        refute Repo.in_transaction?()
        send(parent, {:http_entered, self()})

        receive do
          :continue ->
            Req.Test.json(conn, %{"access_token" => "new-selected", "expires_in" => 3600})
        after
          5_000 -> flunk("HTTP barrier timeout")
        end
      end)

      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Connect.resolve_credential(ctx.c, %{person_id: ctx.person.id}, @opts)
          end)
        end)

      assert_receive {:http_entered, pid}, 5_000
      Sandbox.unboxed_run(Repo, fn -> mutate(@mutation, ctx, selected) end)
      send(pid, :continue)
      result = Task.await(task, 5_000)

      if @reason do
        expected = %{credential_id: ctx.c.id, reason: @reason}

        expected =
          if @reason == :person_unavailable,
            do: expected,
            else: Map.put(expected, :owner_type, "person")

        assert result == {:error, expected}
      else
        assert {:ok, r} = result

        assert {r.grant_id, r.owner_id, r.authentication} ==
                 {ctx.personal.id, ctx.person.id, %{access_token: "new-selected"}}
      end
    end
  end

  for {stage, mutation, reason} <- [
        {1, :replace, :credential_unavailable},
        {2, :replace, :credential_unavailable},
        {2, :config, :credential_unavailable},
        {2, :remove, :credential_unavailable},
        {2, :person, :person_unavailable},
        {2, :unreadable_refresh, :credential_unavailable},
        {2, :new_personal, :credential_unavailable}
      ] do
    @stage stage
    @mutation mutation
    @reason reason
    test "cached OAuth commit #{@stage}: #{@mutation} cannot return known superseded material",
         ctx do
      Sandbox.unboxed_run(Repo, fn ->
        Repo.update!(Ecto.Changeset.change(ctx.personal, refresh_token: nil))

        if @mutation == :new_personal,
          do: Connect.remove_credential_grant(ctx.c, {:person, ctx.person.id})
      end)

      parent = self()

      task =
        Task.async(fn ->
          receive do
            :start ->
              Sandbox.unboxed_run(Repo, fn ->
                Connect.resolve_credential(ctx.c, %{person_id: ctx.person.id}, @opts)
              end)
          end
        end)

      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.pause_commit/4, %{
          caller: task.pid,
          parent: parent,
          stage: @stage
        })

      on_exit(fn -> :telemetry.detach(handler) end)
      send(task.pid, :start)
      assert_receive {:committed, pid}, 5_000

      Sandbox.unboxed_run(Repo, fn ->
        case @mutation do
          :unreadable_refresh ->
            Repo.query!(
              "UPDATE connect_grants SET refresh_token = 'enc:v1:broken' WHERE id = $1",
              [ctx.personal.id]
            )

          :new_personal ->
            Connect.replace_credential_grant(ctx.c, {:person, ctx.person.id}, %{
              access_token: "new-personal"
            })

          other ->
            mutate(other, ctx, ctx.personal)
        end
      end)

      send(pid, :continue)
      expected = %{credential_id: ctx.c.id, reason: @reason}

      expected =
        cond do
          @reason == :person_unavailable -> expected
          @mutation == :new_personal -> Map.put(expected, :owner_type, "org")
          true -> Map.put(expected, :owner_type, "person")
        end

      assert Task.await(task, 5_000) == {:error, expected}
    end
  end

  # Observe real committed SQL boundaries; no production callbacks or internal mocks.
  def advance_after_refresh(_, _, metadata, %{caller: caller, clock: clock}) do
    if self() == caller and metadata.query == "commit" and Process.delete(:advance_after_refresh) do
      Agent.update(clock, fn _ -> DateTime.add(@now, 40) end)
    end
  end

  def pause_commit(_event, _measurements, metadata, config) do
    if self() == config.caller and metadata.query == "commit" do
      count = Process.get({__MODULE__, :commits}, 0) + 1
      Process.put({__MODULE__, :commits}, count)

      if count == config.stage do
        send(config.parent, {:committed, self()})

        receive do
          :continue -> :ok
        after
          5_000 -> raise "commit barrier timeout"
        end
      end
    end
  end

  defp mutate(:none, _, _), do: :ok

  defp mutate(:replace, ctx, _),
    do:
      Connect.replace_credential_grant(ctx.c, {:person, ctx.person.id}, %{access_token: "newer"})

  defp mutate(:revoke, ctx, _),
    do: Connect.revoke_credential_grant(ctx.c, {:person, ctx.person.id})

  defp mutate(:remove, ctx, _),
    do: Connect.remove_credential_grant(ctx.c, {:person, ctx.person.id})

  defp mutate(:config, ctx, _),
    do: Repo.update!(Ecto.Changeset.change(ctx.c, auth_kind: "api_key"))

  defp mutate(kind, ctx, _) when kind in [:person, :disabled_person], do: Repo.delete!(ctx.person)

  defp mutate(:ciphertext, _, g),
    do:
      Repo.query!("UPDATE connect_grants SET access_token = 'enc:v1:broken' WHERE id = $1", [g.id])
end
