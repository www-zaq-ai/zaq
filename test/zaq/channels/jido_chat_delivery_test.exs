defmodule Zaq.Channels.JidoChatDeliveryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Jido.Chat.Mattermost.Adapter
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.{ChannelConfig, JidoChatBridge}
  alias Zaq.Engine.{Events, PeopleAuthGateway}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.TestSupport.OpenAIStub

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: Adapter}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, registry: previous}
  end

  for provider <- ["mattermost", :mattermost], thread_id <- [nil, "root-post"] do
    @provider provider
    @thread_id thread_id
    test "real Thread creates #{inspect(provider)} notification with root #{inspect(thread_id)}" do
      connection = http_server()

      outgoing = %Outgoing{
        provider: @provider,
        channel_id: "private-room",
        thread_id: @thread_id,
        body: "Synthetic private code 1234-5678",
        metadata: %{"subject" => "Sign-in"}
      }

      assert :ok = JidoChatBridge.send_reply(outgoing, connection)
      assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
      expected = %{"channel_id" => "private-room", "message" => outgoing.body}
      expected = if @thread_id, do: Map.put(expected, "root_id", @thread_id), else: expected
      assert Jason.decode!(body) == expected
    end
  end

  test "ordinary string-provider status edit uses the real adapter edit payload" do
    connection = http_server()

    outgoing = %Outgoing{
      provider: "mattermost",
      channel_id: "private-room",
      body: "Updated answer",
      metadata: %{message_id: "status-post"}
    }

    assert :ok = JidoChatBridge.send_reply(outgoing, connection)
    assert_received {:openai_request, "PUT", "/api/v4/posts/status-post", "", body}
    assert Jason.decode!(body) == %{"id" => "status-post", "message" => "Updated answer"}
    refute_received {:openai_request, "POST", _, _, _}
  end

  test "unsupported providers retain the controlled delivery error without interning strings" do
    unknown = "unregistered-provider-#{System.unique_integer([:positive])}"

    for provider <- [unknown, nil, :unsupported] do
      outgoing = %Outgoing{provider: provider, channel_id: "private-room", body: "Harmless"}

      assert {:error, {:unsupported_provider, ^provider}} =
               JidoChatBridge.send_reply(outgoing, %{url: "http://unused.invalid", token: "test"})
    end

    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(unknown, :utf8) end
  end

  property "registered provider strings and atoms pass the bridge's real Thread constructor", %{
    registry: registry
  } do
    Application.put_env(:zaq, :channels, registry)
    # Read the production registry, rather than maintaining another provider enumeration.
    providers = for {provider, %{adapter: _}} <- registry, do: provider

    check all(provider <- member_of(providers), string? <- boolean()) do
      input = if string?, do: Atom.to_string(provider), else: provider
      assert {:ok, _adapter} = JidoChatBridge.adapter_for(input)
      assert JidoChatBridge.provider_to_atom(input) === provider

      incoming = %Jido.Chat.Incoming{
        external_room_id: "private-room",
        channel_meta: %Jido.Chat.ChannelMeta{adapter_name: input},
        author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
      }

      assert :ok =
               JidoChatBridge.handle_from_listener(
                 %{provider: input, url: "http://unused.invalid", token: "test"},
                 incoming,
                 []
               )
    end
  end

  test "listener config string passes the real Thread constructor before ignoring the bot's message" do
    incoming = %Jido.Chat.Incoming{
      external_room_id: "private-room",
      author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
    }

    assert :ok =
             JidoChatBridge.handle_from_listener(
               %{provider: "mattermost", url: "http://unused.invalid", token: "test"},
               incoming,
               []
             )
  end

  test "authentication crosses Jido Exec, Engine, Notifications, real Thread and Mattermost HTTP" do
    connection = http_server()
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        event =
          Events.build_and_dispatch_invoke_event(
            %{op: :request_challenge, email: person.email, ip: {127, 0, 3, 41}},
            :people_auth,
            event_opts: [confidential: true]
          )

        assert {:ok, descriptor} = event.response

        assert Enum.sort(Map.keys(descriptor)) == [
                 :challenge_id,
                 :expires_at,
                 :resend_available_at
               ]

        assert {:ok, ^descriptor} = PeopleAuth.challenge_status(descriptor.challenge_id)
        assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
        payload = Jason.decode!(body)
        assert payload["channel_id"] == "private-room"
        refute Map.has_key?(payload, "root_id")
        [_, code] = Regex.run(~r/\*\*([0-9]{4}-[0-9]{4})\*\*/, payload["message"])

        assert payload["message"] ==
                 "Your ZAQ sign-in code is\n\n**#{code}**\n\nDo not share this code.\n\n*Input this code in the current Sign-in page*"

        send(self(), {:delivered_code, code})

        row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
        assert row.status == "sent"
        assert row.payload["body"] == payload["message"]

        assert {:ok, %{token: token}} =
                 PeopleAuthGateway.dispatch(
                   %{op: :verify, challenge_id: descriptor.challenge_id, code: code},
                   []
                 )

        assert {:ok, %{person: authenticated}} =
                 PeopleAuthGateway.dispatch(%{op: :authenticate, token: token}, [])

        assert authenticated.id == person.id
      end)

    assert_received {:delivered_code, code}
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  test "real HTTP delivery failure invalidates its exact challenge and stores a failed notification" do
    connection = http_server(403)
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} =
                 PeopleAuthGateway.request_challenge(person.email, {127, 0, 3, 42})
      end)

    assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, Jason.decode!(body)["message"])
    challenge = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert challenge.invalidated_at
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(challenge.id)
    row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
    assert row.status == "failed"
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  defp http_server(status \\ 201) do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]
          payload = Jason.decode!(body)
          {status, Map.merge(payload, %{"id" => "sent-post", "create_at" => 0})}
        end,
        self()
      )

    start_supervised!(child)
    %{url: String.trim_trailing(endpoint, "/v1"), token: "synthetic-token"}
  end

  defp authentication_person(connection) do
    {:ok, _} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Synthetic delivery",
        kind: "retrieval",
        enabled: true,
        url: connection.url,
        token: connection.token
      })

    {:ok, person} =
      People.create_person(%{full_name: "Delivery", email: "delivery@example.test"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "private-room",
        weight: 0
      })

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    person
  end
end
