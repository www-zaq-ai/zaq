defmodule Zaq.Channels.WebBridgeProfileTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties
  import Zaq.CommunicationFixtures
  alias Zaq.Accounts.People
  alias Zaq.Channels.{CommunicationBridge, WebBridge}
  alias Zaq.Channels.Web.{Command, Context, Delivery, Response}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver
  alias Zaq.TestSupport.ChannelConversationBoundary

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous || %{}, :web_widget, %{bridge: WebBridge})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    if is_nil(Process.whereis(Zaq.Channels.Supervisor)) do
      start_supervised!(%{
        id: Zaq.Channels.Supervisor,
        start:
          {Supervisor, :start_link, [[], [strategy: :one_for_one, name: Zaq.Channels.Supervisor]]}
      })
    end

    config = connector_fixture("web_widget")
    connector_fixture("email")
    %{scope: %{provider: "web_widget", channel_config_id: config.id, sender_id: "external-user"}}
  end

  defp profiled(scope, profile) do
    Map.put(scope, :profile_context, %{
      sender_id: scope.sender_id,
      channel_config_id: scope.channel_config_id,
      profile: profile
    })
  end

  test "initialization privately binds the resolved Person, independent of page", %{scope: scope} do
    {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    {:ok, command} = Command.new(%{type: :conversation_init, request_id: "init"})

    bindings =
      for page <- ["first-page", "refreshed-page"] do
        {:ok, delivery} =
          Delivery.new(%{
            consumer: :widget,
            channel_config_id: scope.channel_config_id,
            topic: page,
            events: %{typing: "response.typing"}
          })

        {:ok, context} =
          Context.new(nil,
            consumer: :widget,
            sender_id: scope.sender_id,
            channel_config_id: scope.channel_config_id,
            delivery: delivery
          )

        assert %{
                 response: %Response{type: :widget_initialized, payload: public},
                 delivery_binding: %Delivery{} = binding
               } =
                 WebBridge.from_listener(%{}, command, context: context)

        refute Map.has_key?(public, :person_id)
        refute Map.has_key?(public, :delivery_binding)
        refute Map.has_key?(public, :topic)
        assert binding.topic == "web_widget:recipient:#{scope.channel_config_id}:#{person.id}"
        binding
      end

    assert hd(bindings) == List.last(bindings)
  end

  property "recipient topics separate resolved People and connectors", %{scope: scope} do
    check all(suffix <- positive_integer(), max_runs: 5) do
      other_scope = %{scope | sender_id: "other-#{suffix}"}

      other_config =
        Repo.insert!(%Zaq.Engine.ChannelConfig{
          name: "Other widget #{suffix}",
          provider: "web_widget",
          kind: "retrieval",
          enabled: true,
          token: "",
          url: ""
        })

      topics =
        for current <- [scope, other_scope, %{scope | channel_config_id: other_config.id}] do
          {:ok, command} = Command.new(%{type: :conversation_init, request_id: "scope-init"})

          {:ok, context} =
            Context.new(nil,
              consumer: :widget,
              sender_id: current.sender_id,
              channel_config_id: current.channel_config_id
            )

          assert %{delivery_binding: binding} =
                   WebBridge.from_listener(%{}, command, context: context)

          binding.topic
        end

      assert length(Enum.uniq(topics)) == 3
    end
  end

  test "different verified sender IDs resolving to one Person share a binding", %{scope: scope} do
    topics =
      for sender <- ["parent-account", "linked-parent-account"] do
        current =
          profiled(%{scope | sender_id: sender}, %{
            email: "same-person@example.com",
            full_name: "Same Person"
          })

        {:ok, command} = Command.new(%{type: :conversation_init, request_id: "linked-init"})

        {:ok, context} =
          Context.new(nil,
            consumer: :widget,
            sender_id: sender,
            channel_config_id: scope.channel_config_id,
            profile_context: current.profile_context
          )

        assert %{delivery_binding: binding} =
                 WebBridge.from_listener(%{}, command, context: context)

        binding.topic
      end

    assert hd(topics) == List.last(topics)
  end

  property "transient profile binding survives serialization and cannot select another sender", %{
    scope: scope
  } do
    check all(name <- string(:utf8, max_length: 80), id <- positive_integer(), max_runs: 20) do
      scoped = profiled(scope, %{full_name: name})
      transported = scoped |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])

      assert {:ok, %{display_name: ^name, channel_id: "external-user"}} =
               WebBridge.fetch_profile(scope.sender_id, transported)

      assert {:error, :invalid_profile} = WebBridge.fetch_profile("another-#{id}", transported)
    end
  end

  test "bridge alone maps profile fields and enforces sender binding", %{scope: scope} do
    scoped =
      profiled(scope, %{
        "full_name" => "Ada",
        "email" => "ada@example.com",
        "phone" => "+14155550123",
        "channel_id" => "spoof"
      })

    assert {:ok,
            %{
              channel_id: "external-user",
              display_name: "Ada",
              email: "ada@example.com",
              phone: "+14155550123"
            }} = WebBridge.fetch_profile(scope.sender_id, scoped)

    assert {:error, :invalid_profile} = WebBridge.fetch_profile("different", scoped)

    assert {:error, :invalid_profile} =
             WebBridge.fetch_profile(scope.sender_id, %{
               scoped
               | channel_config_id: scope.channel_config_id + 1
             })

    assert {:error, :not_found} = WebBridge.fetch_profile(scope.sender_id, scope)
  end

  test "initialization persists profile and later messages need only normalized identity", %{
    scope: scope
  } do
    profiled_scope =
      profiled(scope, %{
        full_name: "Ada Lovelace",
        email: "ada@example.com",
        phone: "+14155550123"
      })

    assert {:ok, _} = ChannelConversationBoundary.initialize(profiled_scope)

    assert {:ok, person} =
             People.match_by_channel("web_widget", scope.sender_id, scope.channel_config_id)

    assert person.full_name == "Ada Lovelace"
    assert person.email == "ada@example.com"
    assert person.phone == "+14155550123"

    incoming =
      Incoming.new(%{
        provider: :web_widget,
        author_id: scope.sender_id,
        channel_id: Ecto.UUID.generate(),
        content: "Hello",
        message_id: Ecto.UUID.generate(),
        routing_context: %{
          channel_config_id: scope.channel_config_id,
          conversation_type: :one_to_one
        }
      })

    incoming = CommunicationBridge.put_conversation_identity(incoming)
    assert {:ok, bound} = ChannelConversationBoundary.prepare(scope, incoming)
    assert bound.person == IdentityResolver.person_payload(person)
  end

  test "existing People are matched by email and phone", %{scope: scope} do
    {:ok, email_person} = People.create_person(%{full_name: "Email", email: "known@example.com"})
    {:ok, phone_person} = People.create_person(%{full_name: "Phone", phone: "+14155550124"})

    for {sender, profile, person} <- [
          {"email-user", %{email: "KNOWN@example.com"}, email_person},
          {"phone-user", %{phone: "+14155550124"}, phone_person}
        ] do
      scoped = profiled(%{scope | sender_id: sender}, profile)
      assert {:ok, resolved} = IdentityResolver.resolve_channel_sender(scoped)
      assert resolved.id == person.id
    end
  end

  test "invalid evidence and conflicting owners cannot create a link", %{scope: scope} do
    {:ok, _} = People.create_person(%{full_name: "Email", email: "owner@example.com"})
    {:ok, _} = People.create_person(%{full_name: "Phone", phone: "+14155550125"})

    for profile <- [
          %{email: "owner@example.com", phone: "+14155550125"},
          %{full_name: %{invalid: true}}
        ] do
      assert {:error, :unauthorized} =
               IdentityResolver.resolve_channel_sender(profiled(scope, profile))

      assert {:error, :not_found} =
               People.match_by_channel("web_widget", scope.sender_id, scope.channel_config_id)
    end

    assert {:ok, legacy} = IdentityResolver.resolve_channel_sender(scope)
    assert legacy.full_name == scope.sender_id
  end
end
