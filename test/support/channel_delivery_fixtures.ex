defmodule Zaq.ChannelDeliveryFixtures do
  @moduledoc false

  alias Zaq.Accounts.People
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo

  def stored_channel_answer(opts \\ []) do
    person =
      Keyword.get_lazy(opts, :person, fn ->
        {:ok, person} = People.create_person(%{"full_name" => "Delivery reader"})
        person
      end)

    config = Keyword.get_lazy(opts, :config, &connector/0)
    message_id = Keyword.get_lazy(opts, :message_id, &Ecto.UUID.generate/0)
    room = Keyword.get(opts, :room, "room")

    {:ok, captured} =
      Conversations.capture_canonical_message(
        %Facts{
          provider: config.provider,
          channel_config_id: config.id,
          channel_id: room,
          kind: :channel,
          actor_person_id: person.id
        },
        %{
          role: "external",
          content: "Question",
          author_id: "sender",
          external_message_id: message_id
        },
        %{provider: config.provider, channel_config_id: config.id, provenance: "channel_adapter"}
      )

    incoming =
      Incoming.new(%{
        content: "Question",
        channel_id: room,
        provider: :mattermost,
        author_id: "sender",
        message_id: message_id,
        person: if(Keyword.get(opts, :private_execution, false), do: person),
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    {:ok, binding} = Conversations.admit_incoming(incoming)

    finalization_opts = Keyword.take(opts, [:history_updates_node_router])

    finalization_opts =
      if Keyword.get(opts, :private_execution, false),
        do: Keyword.put(finalization_opts, :actor, %{person: %{id: person.id}}),
        else: finalization_opts

    {:ok, %{assistant_message_id: answer_id}} =
      Conversations.finalize_incoming(
        binding.user_message_id,
        binding.finalization_token,
        Map.merge(
          %{answer: "Stored answer", error: false, trace: Keyword.get(opts, :trace, [])},
          Keyword.get(opts, :result, %{})
        ),
        finalization_opts
      )

    %{
      config: config,
      person: person,
      input: Repo.get!(Message, binding.user_message_id),
      answer: Repo.get!(Message, answer_id),
      captured: captured,
      binding: binding
    }
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Delivery evidence",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://example.invalid",
      token: "fixture-token"
    })
    |> Repo.insert!()
  end
end
