defmodule Zaq.Engine.PeopleProfileGatewayTest do
  use Zaq.DataCase, async: true
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissionGrant, PeoplePermissions, PersonSession}
  alias Zaq.Engine.{Api, Events, PeopleAuthGateway}

  setup do
    Repo.delete_all(PeoplePermissionGrant)

    {:ok, p} =
      People.create_person(%{
        full_name: "Profile",
        email: "gateway-profile@example.test",
        metadata: %{"secret" => "private"}
      })

    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, c} = PeopleAuth.issue_challenge(p, {127, 2, 1, 1})

    {:ok, %{token: token, session: session}} =
      PeopleAuth.verify_challenge(c.challenge_id, c.code)

    [channel] = People.list_person_channels(p.id)
    %{person: p, token: token, session: session, channel: channel}
  end

  test "read projection contains only profile fields, own channels/teams and permissions", %{
    person: p,
    token: token,
    session: session
  } do
    {:ok, team} = People.create_team(%{name: "Profile team"})
    {:ok, _} = People.assign_team(p, team.id)
    assert {:ok, profile} = dispatch(:profile, token)
    assert Repo.get!(PersonSession, session.id).last_seen_at
    assert profile.__struct__ == Zaq.Engine.PeopleProfile

    assert profile.person == %{
             full_name: p.full_name,
             email: p.email,
             phone: nil,
             role: nil,
             status: "active"
           }

    assert profile.teams == [%{id: team.id, name: team.name}]

    assert Enum.all?(
             profile.channels,
             &(Enum.sort(Map.keys(&1)) == [:channel_identifier, :id, :platform, :weight])
           )

    refute inspect(profile) =~ "private"
    assert profile.permissions == MapSet.new([:access_profile])
  end

  test "access alone denies forged edits and split-scope grants authorize current owner only", %{
    person: p,
    token: token,
    channel: c
  } do
    assert {:error, :forbidden} =
             dispatch(:update_self_profile, token, %{attrs: %{full_name: "Denied"}})

    assert {:error, :forbidden} =
             dispatch(:update_self_channel_weight, token, %{channel_id: c.id, attrs: %{weight: 4}})

    {:ok, team} = People.create_team(%{name: "Editors"})
    {:ok, _} = People.assign_team(p, team.id)
    {:ok, _} = PeoplePermissions.grant({:team, team.id}, :edit_profile)

    assert {:ok, profile} =
             dispatch(:update_self_profile, token, %{
               person_id: -1,
               attrs: %{full_name: "Saved", email: "bad", status: "inactive"}
             })

    assert profile.person.full_name == "Saved"
    assert profile.person.email == p.email
    assert profile.person.status == "active"

    assert {:ok, profile} =
             dispatch(:update_self_channel_weight, token, %{
               channel_id: c.id,
               attrs: %{weight: "7", person_id: -1, platform: "slack"}
             })

    assert hd(profile.channels).weight == 7
    assert hd(profile.channels).platform == "email"
    assert People.get_channel(c.id).last_interaction_at == c.last_interaction_at
    {:ok, _} = PeoplePermissions.revoke({:team, team.id}, :edit_profile)

    assert {:error, :forbidden} =
             dispatch(:update_self_profile, token, %{attrs: %{full_name: "Stale"}})

    assert {:ok, _} = dispatch(:profile, token)
    assert People.get_person(p.id).full_name == "Saved"
  end

  test "invalid edits and foreign channels cannot mutate or disclose another identity", %{
    person: p,
    token: token,
    channel: c
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)

    {:ok, other} =
      People.create_person(%{full_name: "Other", email: "other-gateway@example.test"})

    [foreign] = People.list_person_channels(other.id)

    for id <- [foreign.id, 999_999, nil, "bad"] do
      assert {:error, :not_found} =
               dispatch(:update_self_channel_weight, token, %{channel_id: id, attrs: %{weight: 8}})
    end

    assert {:error, %Ecto.Changeset{}} =
             dispatch(:update_self_profile, token, %{attrs: %{full_name: %{}}})

    assert {:error, %Ecto.Changeset{}} =
             dispatch(:update_self_channel_weight, token, %{
               channel_id: c.id,
               attrs: %{weight: -1}
             })

    assert People.get_person(p.id).full_name == p.full_name
    assert People.get_channel(foreign.id).weight == foreign.weight
    assert {:error, :invalid_request} = dispatch(:update_self_profile, token, %{attrs: nil})
  end

  test "access removal denies edit-only sessions, revocation and merging never follow old credentials",
       %{person: p, token: token, channel: c} do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
    assert {:error, :invalid_session} = dispatch(:profile, token)

    assert {:error, :invalid_session} =
             dispatch(:update_self_channel_weight, token, %{channel_id: c.id, attrs: %{weight: 6}})

    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    assert {:ok, _} = People.merge_persons(survivor, p)

    assert {:error, :invalid_session} =
             dispatch(:update_self_profile, token, %{attrs: %{full_name: "Stale"}})

    assert {:error, :invalid_session} =
             dispatch(:update_self_channel_weight, token, %{channel_id: c.id, attrs: %{weight: 6}})

    assert People.get_person(p.id).full_name == "Survivor"
    assert People.get_channel(c.id).weight == c.weight
  end

  test "outer failure rolls back writes and revoked or malformed credentials deny", %{
    person: p,
    token: token,
    session: session,
    channel: c
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    assert Repo.get!(PersonSession, session.id).last_seen_at == nil

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        dispatch(:update_self_profile, token, %{
                          attrs: %{full_name: "Rolled back"}
                        })

               assert {:ok, _} =
                        dispatch(:update_self_channel_weight, token, %{
                          channel_id: c.id,
                          attrs: %{weight: 9}
                        })

               Repo.rollback(:abort)
             end)

    assert People.get_person(p.id).full_name == p.full_name
    assert People.get_channel(c.id).weight == c.weight
    assert Repo.get!(PersonSession, session.id).last_seen_at == nil
    {:ok, _} = PeopleAuth.revoke_session(token)

    for credential <- [token, nil, "bad", p] do
      assert {:error, :invalid_session} =
               dispatch(:update_self_profile, credential, %{attrs: %{full_name: "Denied"}})
    end
  end

  defp dispatch(op, token, params \\ %{}),
    do: PeopleAuthGateway.dispatch(Map.merge(params, %{op: op, token: token}), [])

  test "order command derives authority from bearer and rejects stale state", %{
    person: p,
    token: token,
    channel: c
  } do
    params = %{ids: [c.id], expected: [%{id: c.id, weight: c.weight}], person_id: -1}
    assert {:error, :forbidden} = dispatch(:update_self_channel_order, token, params)
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    assert {:ok, profile} = dispatch(:update_self_channel_order, token, params)
    refute inspect(profile) =~ token
    assert hd(profile.channels).id == c.id
    {:ok, _} = People.update_self_channel_weight(p, c.id, %{weight: 10})
    assert {:error, :stale_order} = dispatch(:update_self_channel_order, token, params)

    assert {:error, :invalid_order} =
             dispatch(:update_self_channel_order, token, %{ids: nil, expected: nil})

    {:ok, _} = PeoplePermissions.revoke(:all_people, :edit_profile)
    assert {:error, :forbidden} = dispatch(:update_self_channel_order, token, params)
    assert {:error, :invalid_session} = dispatch(:update_self_channel_order, nil, params)
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, _} = People.update_person(p, %{status: "inactive"})
    assert {:error, :invalid_session} = dispatch(:update_self_channel_order, token, params)
    assert People.get_channel(c.id).weight == 10
  end

  test "order API requires confidential envelope and excludes bearer from diagnostics", %{
    token: token,
    channel: c
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)

    request = %{
      op: :update_self_channel_order,
      token: token,
      ids: [c.id],
      expected: [%{id: c.id, weight: c.weight}]
    }

    event = Events.build_invoke_event(request, :people_auth)

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :people_auth, %{})

    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        event =
          Events.build_and_dispatch_invoke_event(request, :people_auth,
            event_opts: [confidential: true],
            node_router: Zaq.NodeRouter
          )

        assert event.opts[:confidential]
        assert {:ok, profile} = event.response
        refute inspect(profile) =~ token
      end)

    refute log =~ token
    refute_received {:node_router_event, %{request: %{op: :update_self_channel_order}}}
  end
end
