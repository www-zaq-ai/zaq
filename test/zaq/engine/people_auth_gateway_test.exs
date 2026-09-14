defmodule Zaq.Engine.PeopleAuthGatewayTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.{ChannelConfig, PeopleAuthDeliveryMock}
  alias Zaq.Engine.{Events, PeopleAuthGateway}
  alias Zaq.TestSupport.PeopleAuthDelivery
  import Mox

  setup :verify_on_exit!

  test "sent delivery returns only descriptor and the delivered code verifies through confidential events" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Sent", email: "sent@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    parent = self()

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      refute Repo.in_transaction?()
      assert outgoing.body =~ ~r/\b[0-9]{4}-[0-9]{4}\b/
      assert outgoing.channel_id == person.email
      send(parent, {:delivered, outgoing.body})
      :ok
    end)

    event =
      Events.build_and_dispatch_invoke_event(
        %{op: :request_challenge, email: person.email, ip: {127, 0, 2, 21}},
        :people_auth,
        event_opts: [confidential: true]
      )

    assert {:ok, descriptor} = event.response
    assert event.actor == nil
    assert Enum.sort(Map.keys(descriptor)) == [:challenge_id, :expires_at]
    assert_received {:delivered, body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, body)

    assert {:ok, %{token: token}} =
             PeopleAuthGateway.dispatch(
               %{op: :verify, challenge_id: descriptor.challenge_id, code: code},
               []
             )

    assert {:ok, %{person: current}} =
             PeopleAuthGateway.dispatch(%{op: :authenticate, token: token}, [])

    assert current.id == person.id
    assert {:ok, _} = PeopleAuthGateway.dispatch(%{op: :revoke, token: token}, [])
    refute_received {:node_router_event, %{opts: [{:action, :people_auth} | _]}}
    refute_received {:node_router_event, %{request: %Zaq.Engine.Messages.Outgoing{}}}
    refute_received {:node_router_event, %{request: %{person_id: _, message: _}}}
  end

  test "delivery A failing after replacement B is issued invalidates only A" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Race", email: "race@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    ip = {127, 0, 2, 22}
    parent = self()

    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ ->
      {:ok, replacement} = PeopleAuth.issue_challenge(person, ip)
      send(parent, {:replacement, replacement})
      {:error, :transport_failed}
    end)

    assert {:error, :delivery_failed} = PeopleAuthGateway.request_challenge(person.email, ip)
    assert_received {:replacement, replacement}
    assert {:ok, _} = PeopleAuth.challenge_status(replacement.challenge_id)
  end

  test "late successful delivery cannot return a superseded challenge" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Late", email: "late@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    ip = {127, 0, 2, 23}
    parent = self()

    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ ->
      {:ok, replacement} = PeopleAuth.issue_challenge(person, ip)
      send(parent, {:replacement, replacement})
      :ok
    end)

    assert {:error, :delivery_failed} = PeopleAuthGateway.request_challenge(person.email, ip)
    assert_received {:replacement, replacement}
    assert {:ok, _} = PeopleAuth.challenge_status(replacement.challenge_id)
  end

  test "delivery exception invalidates the issued challenge without exposing exception text" do
    PeopleAuthDelivery.setup()

    {:ok, person} =
      People.create_person(%{full_name: "Exception", email: "exception@example.test"})

    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    parent = self()

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      send(parent, {:secret_body, outgoing.body})

      Function.capture(PeopleAuthDeliveryMock, :missing_post, 2).(
        outgoing.body,
        "private-transport-token"
      )
    end)

    log =
      ExUnit.CaptureLog.capture_log(
        [
          level: :warning,
          metadata: [:phase, :exception_type, :source_module, :source_function, :source_arity]
        ],
        fn ->
          assert {:error, :delivery_failed} =
                   PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 24})
        end
      )

    assert_received {:secret_body, body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, body)
    assert log =~ "UndefinedFunctionError"
    assert log =~ "missing_post"
    assert log =~ "phase=execution"
    refute log =~ body
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
    refute log =~ "private-transport-token"
    refute log =~ person.email

    assert Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id).invalidated_at
  end

  test "resolved canonical target crosses the real action and Engine boundaries" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Action", email: "action@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    parent = self()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :notify_person
      assert event.opts[:confidential] == true
      assert event.request.person_id == person.id
      send(parent, :action_dispatched)
      Zaq.NodeRouter.dispatch(event)
    end)

    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ -> :ok end)

    assert {:ok, descriptor} =
             PeopleAuthGateway.request_challenge(
               " ACTION@example.test ",
               {127, 0, 2, 30},
               node_router_module: Zaq.NodeRouterMock
             )

    assert_received :action_dispatched
    assert Enum.sort(Map.keys(descriptor)) == [:challenge_id, :expires_at]
  end

  test "malformed transport receipt fails real Jido output validation and invalidates challenge" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Receipt", email: "receipt@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ -> {:ok, %{message_id: 123}} end)

    log =
      ExUnit.CaptureLog.capture_log([level: :warning, metadata: [:phase]], fn ->
        assert {:error, :delivery_failed} =
                 PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 31})
      end)

    assert log =~ "phase=validation"

    assert Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id).invalidated_at
  end

  test "known ineligible target records identification failure; issuance limits do not" do
    {:ok, person} =
      People.create_person(%{
        full_name: "Inactive",
        email: "inactive@example.test",
        status: "inactive"
      })

    assert {:error, :failed_identification} =
             PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 25})

    assert {:error, :invalid_request} =
             PeopleAuthGateway.dispatch(%{op: :revoke_all, person_id: person.id}, [])

    {:ok, person} = People.update_person(person, %{status: "active"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, _} = Zaq.System.save_people_access_config(%{otp_send_person_limit: 1})
    {:ok, _} = PeopleAuth.issue_challenge(person, {127, 0, 2, 25})

    assert {:error, :request_unavailable} =
             PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 25})
  end

  test "unknown email is read-only and reports only failed identification" do
    assert {:error, :failed_identification} =
             PeopleAuthGateway.request_challenge("missing@example.test", {127, 0, 0, 21})

    assert Repo.aggregate(PersonLoginChallenge, :count) == 0
  end

  test "historical email-channel identities match without creating or editing a Person" do
    PeopleAuthDelivery.setup()

    {:ok, person} =
      People.create_person(%{full_name: "Historical", email: "historical@example.test"})

    {:ok, _} = People.update_person(person, %{email: nil})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      assert outgoing.channel_id == "historical@example.test"
      :ok
    end)

    assert {:ok, _} =
             PeopleAuthGateway.request_challenge(" HISTORICAL@example.test ", {127, 0, 2, 26})

    assert People.get_person(person.id).email == nil
  end

  test "preferred channel failure uses the existing fallback and still returns only a descriptor" do
    PeopleAuthDelivery.setup()

    Application.put_env(:zaq, :channels, %{
      email: %{bridge: PeopleAuthDeliveryMock},
      slack: %{bridge: PeopleAuthDeliveryMock}
    })

    {:ok, _} =
      ChannelConfig.upsert_by_provider("slack", %{
        name: "Fallback",
        kind: "retrieval",
        url: "https://test.invalid",
        token: "test-only"
      })

    {:ok, person} = People.create_person(%{full_name: "Fallback", email: "fallback@example.test"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "slack",
        channel_identifier: "fallback-person",
        weight: 1
      })

    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      assert outgoing.channel_id == person.email
      {:error, :unavailable}
    end)

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      assert outgoing.channel_id == "fallback-person"
      :ok
    end)

    assert {:ok, descriptor} = PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 29})
    assert Enum.sort(Map.keys(descriptor)) == [:challenge_id, :expires_at]
  end

  test "delivery-time permission removal fails closed and invalidates the challenge" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Revoked", email: "revoked@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)

    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ ->
      {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
      :ok
    end)

    assert {:error, :delivery_failed} =
             PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 27})

    assert Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id).invalidated_at
  end

  test "delivery exit/timeout is cleaned up and nonconfidential auth calls are rejected" do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.create_person(%{full_name: "Timeout", email: "timeout@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    expect(PeopleAuthDeliveryMock, :send_reply, fn _, _ -> exit(:timeout) end)

    assert {:error, :delivery_failed} =
             PeopleAuthGateway.request_challenge(person.email, {127, 0, 2, 28})

    assert Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id).invalidated_at

    event = Events.build_and_dispatch_invoke_event(%{op: :authenticate, token: nil}, :people_auth)
    assert event.response == {:error, :confidential_event_required}
  end

  test "skipped notification is not success and its challenge is invalidated" do
    {:ok, person} = People.create_person(%{full_name: "Portal", email: "portal@example.test"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    Repo.delete_all(Zaq.Channels.ChannelConfig)

    assert {:error, :delivery_failed} =
             PeopleAuthGateway.request_challenge(" PORTAL@example.test ", {127, 0, 0, 22})

    row = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert row.invalidated_at
    assert row.consumed_at == nil
  end
end
