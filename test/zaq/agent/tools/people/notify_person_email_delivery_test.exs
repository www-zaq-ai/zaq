defmodule Zaq.Agent.Tools.People.NotifyPersonEmailDeliveryTest do
  @moduledoc "Real Jido, Notifications and EmailBridge receipts; only SMTP transport is captured."
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Agent.Tools.People.NotifyPerson
  alias Zaq.Channels.{ChannelConfig, PeopleAuthDeliveryMock}
  alias Zaq.Engine.PeopleAuthGateway
  alias Zaq.TestSupport.PeopleAuthDelivery

  setup :verify_on_exit!

  setup do
    {:ok, _} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "Receipt regression",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "", "from_email" => "noreply@example.test", "from_name" => "ZAQ"}
      })

    {:ok, person} =
      People.create_person(%{full_name: "Receipt", email: "real-receipt@example.test"})

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    %{person: person}
  end

  test "delivered email survives actual Jido output validation with its exact receipt", %{
    person: person
  } do
    result =
      Jido.Exec.run(
        NotifyPerson,
        %{person: %{id: person.id}, subject: "Receipt", message: "**Delivered**"},
        %{},
        timeout: 0
      )

    assert_receive {:email, email}
    assert email.html_body =~ "<strong>Delivered</strong>"
    assert {:ok, out} = result
    assert out.notified == true
    assert out.status == :sent
    assert email.headers["Message-ID"] == "<#{out.message_id}>"
    assert out.thread_id == out.message_id

    assert out.thread_metadata === %{
             "threading" => %{
               "anchor" => %{
                 "message_id" => out.message_id,
                 "thread_id" => out.thread_id,
                 "references" => [],
                 "in_reply_to" => nil
               }
             }
           }
  end

  test "malformed metadata fails safely without logging the challenge body", %{person: person} do
    PeopleAuthDelivery.setup()
    owner = self()

    expect(PeopleAuthDeliveryMock, :send_reply, fn outgoing, _ ->
      send(owner, {:delivered_body, outgoing.body})
      {:ok, %{thread_metadata: []}}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :delivery_failed} =
                 PeopleAuthGateway.request_challenge(person.email, {127, 0, 5, 6})
      end)

    assert_received {:delivered_body, body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, body)
    assert log =~ "phase=validation"
    assert log =~ "InvalidInputError"
    refute log =~ body
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
    refute log =~ person.email
    challenge = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert challenge.invalidated_at
    assert {:error, _} = PeopleAuth.verify_challenge(challenge.id, code)
  end

  test "real emailed challenge remains valid and authenticates exactly once", %{person: person} do
    result = PeopleAuthGateway.request_challenge(person.email, {127, 0, 5, 5})
    assert_receive {:email, email}
    challenge = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert is_nil(challenge.invalidated_at)
    assert {:ok, descriptor} = result
    assert Enum.sort(Map.keys(descriptor)) == [:challenge_id, :expires_at, :resend_available_at]
    assert descriptor.challenge_id == challenge.id
    assert {:ok, ^descriptor} = PeopleAuth.challenge_status(challenge.id)
    [_, code] = Regex.run(~r/<strong>([0-9]{4}-[0-9]{4})<\/strong>/, email.html_body)
    assert email.html_body =~ "<em>Input this code in the current Sign-in page</em>"
    assert email.text_body =~ code

    assert {:ok, %{token: token}} =
             PeopleAuthGateway.dispatch(
               %{op: :verify, challenge_id: challenge.id, code: code},
               []
             )

    assert {:ok, %{person: authenticated}} =
             PeopleAuthGateway.dispatch(%{op: :authenticate, token: token}, [])

    assert authenticated.id == person.id

    assert {:error, _} =
             PeopleAuthGateway.dispatch(
               %{op: :verify, challenge_id: challenge.id, code: code},
               []
             )
  end
end
