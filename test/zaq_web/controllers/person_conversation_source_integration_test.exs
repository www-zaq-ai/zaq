defmodule ZaqWeb.PersonConversationSourceIntegrationTest do
  use ZaqWeb.ConnCase, async: false
  import Mox
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.TestSupport.{PeopleSourceFixture, PersonResourceConfig}
  alias ZaqWeb.PersonConversationResourceController

  setup :verify_on_exit!

  setup %{conn: conn} do
    Code.ensure_loaded!(PersonResourceConfig)
    {:ok, person} = People.create_person(%{full_name: "Current reader"})
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_message_history)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 9, 7, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    fixture = PeopleSourceFixture.create(person, "Fresh original bytes")

    {:ok, conversation} =
      Conversations.create_conversation(%{person_id: person.id, channel_type: "api"})

    {:ok, message} =
      Conversations.add_message(conversation, %{
        role: "assistant",
        content: "Source",
        sources: [%{"path" => fixture.source}]
      })

    params = %{"id" => conversation.id, "message_id" => message.id, "source" => fixture.source}

    conn =
      conn
      |> init_test_session(%{person_session_token: token})
      |> assign(:config, PersonResourceConfig)

    Map.merge(fixture, %{
      conn: conn,
      person: person,
      token: token,
      conversation: conversation,
      message: message,
      params: params
    })
  end

  test "fresh GetDocument permits an unindexed source and current grant revocation denies it",
       ctx do
    assert Document.get_by_source(ctx.source) == nil
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    expect_hops(ctx, [:people_conversations, :data_source_get_file, :materialize_document])

    result =
      PersonConversationResourceController.show(
        ctx.conn,
        Map.merge(ctx.params, %{
          "provider" => "forged",
          "config_id" => "forged",
          "document_id" => "forged"
        })
      )

    assert response(result, 200) == "Fresh original bytes"
    refute result.resp_body =~ "mat_"
    assert get_resp_header(result, "cache-control") == ["private, no-store"]

    assert_received {:node_router_event,
                     %{opts: describe_opts, actor: actor, next_hop: %{destination: :storage}}}

    assert describe_opts[:action] == :describe_document
    assert actor == ActorNormalizer.from_person_payload(nil, ctx.person)
    refute describe_opts[:skip_permissions]
    refute_received {:node_router_event, %{next_hop: %{destination: :ingestion}}}
    :ok = Permissions.revoke(nil, ctx.grant)
    expect_hops(ctx, [:people_conversations, :data_source_get_file])

    assert response(PersonConversationResourceController.show(ctx.conn, ctx.params), 404) ==
             "Resource not found"
  end

  test "captured trace artifacts follow conversation access without reauthorizing their source",
       ctx do
    actor = ActorNormalizer.from_person_payload(nil, ctx.person)

    assert {:ok, %{record: record}} =
             Jido.Exec.run(
               GetDocument,
               %{
                 provider: "disk",
                 config_id: to_string(ctx.config.id),
                 document_id: ctx.entry.id
               },
               %{actor: actor}
             )

    for metadata <- [
          Record.metadata(record),
          %{"attributes" => %{"source" => ctx.source, "source_type" => "communication_media"}},
          %{"path" => ctx.source, "attributes" => %{"source_type" => "communication_media"}}
        ] do
      params = artifact(ctx, metadata)
      expect_hops(ctx, [:people_conversations])

      assert response(PersonConversationResourceController.show(ctx.conn, params), 200) ==
               "Historical trace bytes"
    end

    :ok = Permissions.revoke(nil, ctx.grant)

    for metadata <- [
          Record.metadata(record),
          %{"attributes" => %{"source" => ctx.source, "source_type" => "communication_media"}},
          %{"path" => ctx.source, "attributes" => %{"source_type" => "communication_media"}}
        ] do
      params = artifact(ctx, metadata)
      expect_hops(ctx, [:people_conversations])

      assert response(PersonConversationResourceController.show(ctx.conn, params), 200) ==
               "Historical trace bytes"
    end

    params =
      artifact(ctx, %{
        "attributes" => %{"source_type" => "communication_media", "provider" => "mattermost"}
      })

    expect_hops(ctx, [:people_conversations])

    assert response(PersonConversationResourceController.show(ctx.conn, params), 200) ==
             "Historical trace bytes"
  end

  test "parent membership and revoked session deny before any resource lookup", ctx do
    {:ok, other} = People.create_person(%{full_name: "Other"})

    {:ok, foreign} =
      Conversations.create_conversation(%{person_id: other.id, channel_type: "api"})

    for params <- [
          Map.put(ctx.params, "source", "data_source/disk/other/private"),
          Map.put(ctx.params, "id", foreign.id),
          Map.put(ctx.params, "message_id", Ecto.UUID.generate())
        ] do
      expect_hops(ctx, [:people_conversations])
      result = PersonConversationResourceController.show(ctx.conn, params)
      assert response(result, 404) == "Resource not found"
      refute result.resp_body =~ ctx.source
    end

    {:ok, _} = PeopleAuth.revoke_session(ctx.token)
    expect_hops(ctx, [:people_conversations])

    assert redirected_to(PersonConversationResourceController.show(ctx.conn, ctx.params)) ==
             "/people/login"
  end

  test "indexed content and persisted handles cannot replace the freshly authorized Record",
       ctx do
    {:ok, _} =
      Document.create(%{
        source: ctx.source,
        content: "Stale indexed text",
        metadata: %{"materialization_handle" => "tampered"}
      })

    expect_hops(ctx, [:people_conversations, :data_source_get_file, :materialize_document])

    assert response(PersonConversationResourceController.show(ctx.conn, ctx.params), 200) ==
             "Fresh original bytes"
  end

  test "unsupported providers and invalid configs fail through the normal Records boundary",
       ctx do
    for source <- ["data_source/unsupported_provider/123/file", "data_source/disk/invalid/file"] do
      {:ok, message} =
        Conversations.add_message(ctx.conversation, %{
          role: "assistant",
          content: "Source",
          sources: [%{"path" => source}]
        })

      expect_hops(ctx, [:people_conversations, :data_source_get_file])
      params = %{ctx.params | "message_id" => message.id, "source" => source}

      assert response(PersonConversationResourceController.show(ctx.conn, params), 404) ==
               "Resource not found"
    end
  end

  defp expect_hops(ctx, actions) do
    for action <- actions do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.opts[:action] == action
        assert event.next_hop.destination in [:engine, :channels, :storage]
        refute event.opts[:skip_permissions]

        assert action == :people_conversations or
                 event.actor == ActorNormalizer.from_person_payload(nil, ctx.person)

        Zaq.NodeRouter.dispatch(event)
      end)
    end
  end

  defp artifact(ctx, record) do
    id = Ecto.UUID.generate()

    {:ok, message} =
      Conversations.add_message(ctx.conversation, %{
        role: "assistant",
        content: "Artifact",
        trace: [%{"artifacts" => [%{"id" => id}]}]
      })

    %MessageTraceArtifact{id: id, message_id: message.id}
    |> MessageTraceArtifact.changeset(
      %{
        tool_call_id: "call",
        tool_name: "download_document",
        name: "trace.txt",
        mime_type: "text/plain",
        content: "Historical trace bytes",
        size: 22,
        sha256: :crypto.hash(:sha256, "Historical trace bytes"),
        record: record
      },
      100
    )
    |> Zaq.Repo.insert!()

    %{"id" => ctx.conversation.id, "message_id" => message.id, "artifact_id" => id}
  end
end
