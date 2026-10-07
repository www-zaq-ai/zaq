defmodule Zaq.Engine.ChannelHistoryProjectionTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.{ChannelConfig, ChannelHistoryProjection}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, Transcript}
  alias Zaq.Engine.History.Facts
  alias Zaq.Repo

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Projection #{System.unique_integer([:positive])}",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "test-token"
      })
      |> Repo.insert!()

    %{config: config}
  end

  test "assistant-only persisted transcript uses connector title fallback", %{config: config} do
    {:ok, captured} = capture(config, "assistant-only", "assistant-message", "assistant", %{})

    row = project_row(captured.transcript_id, config, "Connector / room")

    assert [%{channel_name: "Connector / room", root_message: nil}] =
             ChannelHistoryProjection.project([row])

    {:ok, person} = People.create_person(%{full_name: "Known sender"})

    {:ok, titled} =
      capture(config, "with-sender", "sender-message", "external", %{
        "author_person_id" => person.id,
        "title_style" => "person"
      })

    assert [%{channel_name: "Known sender"}] =
             ChannelHistoryProjection.project([
               project_row(titled.transcript_id, config, "Connector / room")
             ])
  end

  test "person subject title uses archived author metadata when Person is absent", %{
    config: config
  } do
    {:ok, captured} =
      capture(
        config,
        "archived",
        "archived-message",
        "external",
        %{
          "author_person_id" => 9_999_999,
          "title_style" => "person_subject",
          "subject" => "Follow-up"
        },
        "Archived sender"
      )

    Repo.get!(Message, captured.message_id)
    |> Ecto.Changeset.change(
      history_context: %{
        "author_person_id" => 9_999_999,
        "title_style" => "person_subject",
        "subject" => "Follow-up"
      }
    )
    |> Repo.update!()

    assert [%{channel_name: "Archived sender: Follow-up"}] =
             ChannelHistoryProjection.project([
               project_row(captured.transcript_id, config, "Connector fallback")
             ])
  end

  test "thread root resolves its connector-scoped PersonChannel identity", %{config: config} do
    {:ok, person} = People.create_person(%{full_name: "Mapped root author"})

    {:ok, _identity} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "root-author",
        channel_config_id: config.id
      })

    {:ok, root} = capture(config, "root-room", "thread-root", "external", %{}, "Root label")

    {:ok, reply} =
      capture(config, "root-room", "thread-reply", "external", %{}, "Reply author",
        thread_id: "thread-root"
      )

    Repo.get!(Message, root.message_id)
    |> Ecto.Changeset.change(author_id: "root-author", history_context: %{})
    |> Repo.update!()

    assert [
             %{
               root_message: %{
                 message_id: root_id,
                 display_name: "Mapped root author",
                 person_id: person_id
               }
             }
           ] =
             ChannelHistoryProjection.project([
               project_row(reply.transcript_id, config, "Connector fallback")
             ])

    assert root_id == root.message_id
    assert person_id == person.id
  end

  test "unlinked thread root retains author label and has no Person", %{config: config} do
    {:ok, root} =
      capture(config, "unknown-root-room", "unknown-root", "external", %{}, "Root label")

    {:ok, reply} =
      capture(config, "unknown-root-room", "unknown-reply", "external", %{}, "Reply author",
        thread_id: "unknown-root"
      )

    Repo.get!(Message, root.message_id)
    |> Ecto.Changeset.change(
      author_id: "unknown-author",
      author_name: "Unlinked sender",
      history_context: %{}
    )
    |> Repo.update!()

    assert [
             %{
               root_message: %{
                 display_name: "Unlinked sender",
                 person_id: nil,
                 author_id: "unknown-author"
               }
             }
           ] =
             ChannelHistoryProjection.project([
               project_row(reply.transcript_id, config, "Connector fallback")
             ])
  end

  defp capture(
         config,
         channel,
         external_id,
         role,
         history_context,
         author_name \\ "Sender",
         opts \\ []
       ) do
    {:ok, actor} = People.create_person(%{full_name: "Capture actor #{external_id}"})

    {:ok, facts} =
      Facts.for_capture(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: channel,
        kind: :channel,
        actor_person_id: actor.id,
        thread_id: Keyword.get(opts, :thread_id)
      })

    Conversations.capture_canonical_message(
      facts,
      %{
        role: role,
        content: external_id,
        external_message_id: external_id,
        author_id: "external-author",
        author_name: author_name,
        history_context: history_context
      },
      %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_event"}
    )
  end

  defp project_row(id, config, channel_name) do
    transcript = Repo.get!(Transcript, id)

    %{
      id: transcript.id,
      parent_id: transcript.parent_id,
      thread_id: transcript.external_thread_id,
      owner_person_id: transcript.owner_person_id,
      provider: transcript.provider,
      channel_config_id: config.id,
      channel_name: channel_name
    }
  end
end
