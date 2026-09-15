defmodule Zaq.Engine.PeopleConversationsTest do
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.{Conversations, Events, PeopleConversations}
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Storage.Materializers.DiskDocument

  setup do
    {:ok, person} = People.create_person(%{full_name: "Reader"})
    {:ok, other} = People.create_person(%{full_name: "Other"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 9, 8, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)

    {:ok, own} =
      Conversations.create_conversation(%{
        title: "Owned",
        channel_type: "api",
        person_id: person.id
      })

    {:ok, foreign} =
      Conversations.create_conversation(%{
        title: "Foreign",
        channel_type: "api",
        person_id: other.id
      })

    {:ok, message} = Conversations.add_message(own, %{role: "assistant", content: "Answer"})

    {:ok, foreign_message} =
      Conversations.add_message(foreign, %{role: "assistant", content: "Private"})

    %{
      person: person,
      other: other,
      token: token,
      own: own,
      foreign: foreign,
      message: message,
      foreign_message: foreign_message
    }
  end

  test "history is separately granted and operations reauthenticate", ctx do
    assert {:error, :forbidden} = call(ctx, :list)
    grant_history()

    assert {:ok, %{total: 1, conversations: [conv]}} =
             call(ctx, :list, %{person_id: ctx.other.id})

    assert conv.id == ctx.own.id
    assert {:ok, %{messages: [message], can_share: false, shares: []}} = call(ctx, :detail)
    assert message.id == ctx.message.id
    assert {:error, :not_found} = call(ctx, :detail, %{conversation_id: ctx.foreign.id})
    assert {:error, :not_found} = call(ctx, :detail, %{conversation_id: "bad"})
    {:ok, _} = PeopleAuth.revoke_session(ctx.token)
    assert {:error, :invalid_session} = call(ctx, :detail)
  end

  test "paging is bounded and includes archived owned history", ctx do
    grant_history()

    for n <- 1..26 do
      {:ok, _} =
        Conversations.create_conversation(%{
          title: "Archived #{n}",
          channel_type: "slack",
          status: "archived",
          person_id: ctx.person.id
        })
    end

    assert {:ok, %{total: 27, page: 1, conversations: first}} = call(ctx, :list)
    assert length(first) == 25
    assert {:ok, %{total: 27, page: 2, conversations: last}} = call(ctx, :list, %{page: "999"})
    assert length(last) == 2
    assert {:ok, %{total: 26}} = call(ctx, :list, %{status: "archived", channel_type: "slack"})
    assert {:ok, %{total: 1}} = call(ctx, :list, %{status: "active"})
  end

  test "rating derives Person author and cannot cross a message parent", ctx do
    grant_history()

    assert {:ok, rating} =
             call(ctx, :rate, %{
               message_id: ctx.message.id,
               attrs: %{"rating" => 5, "person_id" => ctx.other.id, "user_id" => 123}
             })

    assert rating.person_id == ctx.person.id
    assert rating.user_id == nil

    assert {:error, :not_found} =
             call(ctx, :rate, %{message_id: ctx.foreign_message.id, attrs: %{"rating" => 1}})

    assert {:error, :forbidden} = call(ctx, :delete)
    assert Conversations.get_conversation(ctx.own.id)
  end

  test "share read create revoke all require the extra grant and scoped share id", ctx do
    grant_history()
    assert {:error, :share_forbidden} = call(ctx, :shares)
    assert {:error, :share_forbidden} = call(ctx, :share, %{attrs: %{}})
    {:ok, _} = PeoplePermissions.grant(:all_people, :share_conversations)

    assert {:ok, share} =
             call(ctx, :share, %{attrs: %{"permission" => "read", "shared_with_user_id" => 123}})

    assert share.shared_with_user_id == nil
    assert Conversations.get_conversation_by_token(share.share_token).id == ctx.own.id
    assert {:ok, [^share]} = call(ctx, :shares)
    {:ok, foreign_share} = Conversations.share_conversation(ctx.foreign, %{})
    assert {:error, :not_found} = call(ctx, :revoke_share, %{share_id: foreign_share.id})
    assert {:ok, _} = call(ctx, :revoke_share, %{share_id: share.id})
    assert Conversations.get_conversation_by_token(share.share_token) == nil
    {:ok, _} = PeoplePermissions.revoke(:all_people, :share_conversations)
    assert {:ok, %{can_share: false, shares: []}} = call(ctx, :detail)
  end

  test "fixed event rejects non-confidential requests", ctx do
    event =
      Events.build_and_dispatch_invoke_event(
        %{op: :list, token: ctx.token},
        :people_conversations
      )

    assert event.response == {:error, :confidential_event_required}
    assert {:error, :invalid_request} = PeopleConversations.dispatch(%{}, [])
  end

  test "citations require both bounded message references and current document ACL", ctx do
    grant_history()

    {:ok, document} =
      Document.create(%{
        source: "people-private-source.md",
        content: "Private document"
      })

    {:ok, message} =
      Conversations.add_message(ctx.own, %{
        role: "assistant",
        content: "Citation",
        sources: [%{"path" => document.source}]
      })

    params = %{message_id: message.id, source: document.source}
    assert {:error, :not_found} = call(ctx, :source, params)

    {:ok, _} =
      Permissions.grant({"document", to_string(document.id)}, %{
        person_id: ctx.person.id,
        access_rights: ["read"]
      })

    assert {:ok, %{content: "Private document"}} = call(ctx, :source, params)

    assert {:error, :not_found} =
             call(ctx, :source, %{params | message_id: ctx.foreign_message.id})

    assert {:error, :not_found} = call(ctx, :source, %{params | source: "unreferenced.md"})

    {:ok, binary_source} =
      Conversations.add_message(ctx.own, %{
        role: "assistant",
        content: "Source",
        sources: [%{"type" => "memory"}, %{"path" => document.source}]
      })

    assert {:ok, %{content: "Private document"}} =
             call(ctx, :source, %{params | message_id: binary_source.id})
  end

  test "source references forward no bytes and use only the authenticated actor", ctx do
    grant_history()
    {:ok, handle} = DiskDocument.issue("source")

    {:ok, document} =
      Document.create(%{
        source: "data_source/disk/config/source",
        content: "never forwarded",
        metadata: %{
          "materialization_handle" => handle,
          "actor" => %{"person" => %{"id" => ctx.other.id}}
        }
      })

    {:ok, message} =
      Conversations.add_message(ctx.own, %{
        role: "assistant",
        content: "Citation",
        sources: [%{"path" => document.source}]
      })

    params = %{
      message_id: message.id,
      source: document.source,
      actor: %{person: %{id: ctx.other.id}}
    }

    assert {:error, :not_found} = call(ctx, :source, params)

    Permissions.grant({"document", to_string(document.id)}, %{
      person_id: ctx.person.id,
      access_rights: ["read"]
    })

    assert call(ctx, :source, params) ==
             {:ok,
              %{
                materialization_handle: handle,
                name: document.title,
                mime_type: "application/octet-stream",
                actor: %{person: %{id: ctx.person.id}}
              }}
  end

  test "artifact reads require the owned message and its trace root reference", ctx do
    grant_history()
    alias Zaq.Engine.Conversations.MessageTraceArtifact
    artifact_id = Ecto.UUID.generate()

    {:ok, message} =
      Conversations.add_message(ctx.own, %{
        role: "assistant",
        content: "Artifact",
        trace: [%{"artifacts" => [%{"id" => artifact_id}]}]
      })

    artifact =
      %MessageTraceArtifact{id: artifact_id, message_id: message.id}
      |> MessageTraceArtifact.changeset(
        %{
          tool_call_id: "call",
          tool_name: "media",
          name: "file.txt",
          mime_type: "text/plain",
          content: "bytes",
          size: 5,
          sha256: :crypto.hash(:sha256, "bytes"),
          record: %{"attributes" => %{"source_type" => "communication_media"}}
        },
        100
      )
      |> Repo.insert!()

    params = %{message_id: message.id, artifact_id: artifact.id}
    assert {:ok, %{content: "bytes"}} = call(ctx, :artifact, params)

    assert {:error, :not_found} =
             call(ctx, :artifact, %{params | message_id: ctx.foreign_message.id})

    assert {:error, :not_found} = call(ctx, :artifact, %{params | artifact_id: "invalid"})
    {:ok, document} = Document.create(%{source: "artifact-source.md", content: "source"})

    for record <- [
          %{
            "attributes" => %{"source" => document.source, "source_type" => "communication_media"}
          },
          %{"attributes" => %{"source" => document.source}},
          %{"path" => document.source},
          %{}
        ] do
      Repo.update!(Ecto.Changeset.change(artifact, record: record))
      assert {:error, :not_found} = call(ctx, :artifact, params)
    end

    {:ok, _} =
      Permissions.grant({"document", to_string(document.id)}, %{
        person_id: ctx.person.id,
        access_rights: ["read"]
      })

    Repo.update!(Ecto.Changeset.change(artifact, record: %{"path" => document.source}))
    assert {:ok, %{content: "bytes"}} = call(ctx, :artifact, params)
    Repo.update!(Ecto.Changeset.change(message, trace: [%{"content" => "no artifact reference"}]))
    assert {:error, :not_found} = call(ctx, :artifact, params)
    Repo.update!(Ecto.Changeset.change(message, trace: []))
    assert {:error, :not_found} = call(ctx, :artifact, params)
  end

  test "malformed optional operations remain controlled and pages normalize", ctx do
    grant_history()
    {:ok, _} = PeoplePermissions.grant(:all_people, :share_conversations)
    assert {:error, :invalid_request} = call(ctx, :share, %{attrs: []})
    assert {:ok, %{page: 1}} = call(ctx, :list, %{page: 1})
    assert {:ok, %{page: 1}} = call(ctx, :list, %{page: "invalid"})
    assert {:ok, %{page: 1}} = call(ctx, :list, %{page: -1})
  end

  defp grant_history, do: PeoplePermissions.grant(:all_people, :access_message_history)

  defp call(ctx, op, params \\ %{}) do
    PeopleConversations.dispatch(
      Map.merge(%{op: op, token: ctx.token, conversation_id: ctx.own.id}, params),
      []
    )
  end
end
